; =============================================================================
; BareMetal -- a 64-bit OS written in Assembly for x86-64 systems
; Copyright (C) 2008-2011 Return Infinity -- see LICENSE.TXT
;
; Interrupts
; =============================================================================

align 16
db 'DEBUG: INTERRUPT'
align 16


; -----------------------------------------------------------------------------
; Default exception handler
exception_gate:
	mov rsi, int_string00
	call os_print_string
	mov rsi, exc_string
	call os_print_string
	jmp $				; Hang
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Default interrupt handler
align 16
interrupt_gate:				; handler for all other interrupts
	iretq				; It was an undefined interrupt so return to caller
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Keyboard interrupt. IRQ 0x01, INT 0x21
; This IRQ runs whenever there is input on the keyboard
align 16
keyboard:
	push rax
	push rbx

	xor rax, rax

;keyboard_wait:	
;	in al, 0x64
;	and al, 0x01
;	jz keyboard_wait

	in al, 0x60			; Get the scancode from the keyboard
	cmp al, 0x01
	je keyboard_escape
	cmp al, 0x2A			; Left Shift Make
	je keyboard_shift
	cmp al, 0x36			; Right Shift Make
	je keyboard_shift
	cmp al, 0xAA			; Left Shift Break
	je keyboard_noshift
	cmp al, 0xB6			; Right Shift Break
	je keyboard_noshift
	test al, 0x80
	jz keydown
	jmp keyup

keydown:
	cmp byte [key_shift], 0x00
	jne keyboard_lowercase
	jmp keyboard_uppercase

keyboard_lowercase:
	mov rbx, keylayoutupper
	jmp keyboard_processkey

keyboard_uppercase:	
	mov rbx, keylayoutlower

keyboard_processkey:			; Convert the scancode
	add rbx, rax
	mov bl, [rbx]
	mov [key], bl
	mov al, [key]
	jmp keyboard_done

keyboard_escape:
	jmp reboot

keyup:
	jmp keyboard_done

keyboard_shift:
	mov byte [key_shift], 0x01
	jmp keyboard_done

keyboard_noshift:
	mov byte [key_shift], 0x00
	jmp keyboard_done

keyboard_done:
	mov al, 0x20			; Acknowledge the IRQ
	out 0x20, al
	call os_smp_wakeup_all		; A terrible hack

	pop rbx
	pop rax
	iretq
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Cascade interrupt. IRQ 0x02, INT 0x22
align 16
cascade:
	push rax

	mov al, 0x20			; Acknowledge the IRQ
	out 0x20, al

	pop rax
	iretq
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Real-time clock interrupt. IRQ 0x08, INT 0x28
; Currently this IRQ runs 8 times per second (As defined in init_64.asm)
; The supervisor lives here
align 16
rtc:
	push rax
	push rcx
	push rsi
	push rdi

	cld				; Clear direction flag
	add qword [os_ClockCounter], 1	; 64-bit counter started at bootup

	cmp byte [os_show_sysstatus], 0
	je rtc_no_sysstatus
	call system_status		; Show System Status information on screen
rtc_no_sysstatus:
	
;	Check to make sure that at least one core is running something
	cmp word [os_QueueLen], 0	; Check the length of the Queue
	jne rtc_end			; If it is greater than 0 then skip to the end
	mov rcx, 256
	mov rsi, cpustatus
nextcpu:
	lodsb
	dec rcx
	bt ax, 1			; Is bit 1 set? If so then the CPU is running a job
	jc rtc_end
	cmp rcx, 0
	jne nextcpu
	mov rax, os_command_line	; If nothing is running then restart the CLI
	call os_smp_enqueue

rtc_end:
	mov al, 0x0C			; Select RTC register C
	out 0x70, al			; Port 0x70 is the RTC index, and 0x71 is the RTC data
	in al, 0x71			; Read the value in register C
	mov al, 0x20			; Acknowledge the IRQ on the PICs
	out 0xA0, al
	out 0x20, al

	pop rdi
	pop rsi
	pop rcx
	pop rax
	iretq
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Network interrupt.
align 16
network:
	push rdi
	push rsi
	push rcx
	push rax

	cld				; Clear direction flag
	call os_ethernet_ack_int	; Call the driver function to acknowledge the interrupt internally

	bt ax, 0			; TX bit set (caused the IRQ?)
	jc network_tx			; If so then jump past RX section
	mov byte [os_NetActivity_RX], 1

	; Max size of Ethernet packet: 1518
	; + size: 2 = 1520 = 0x5F0
	; Set each element size to 0x800 (2048). 262144 byte buffer / 2048 = room for 128 packets
	; Deal with the received packet
	; Get current offset in the ring buffer
	mov rdi, os_EthernetBuffer
	xor rax, rax
	mov al, byte [os_EthernetBuffer_C2]
	push rax			; Save the ring element value
	shl rax, 11			; Quickly multiply RAX by 2048
	add rdi, rax
	push rdi
	add rdi, 2
	call os_ethernet_rx_from_interrupt
	pop rdi
	mov rax, rcx
	stosw				; Store the size of the packet
	; increment the offset in the ring buffer
	pop rax				; Restore the ring element value
	add al, 1
	cmp al, 128			; Max element number is 127
	jne network_rx_buffer_nowrap
	xor al, al
network_rx_buffer_nowrap:
	mov byte [os_EthernetBuffer_C2], al

	; Check the packet type
	mov ax, [rdi+12]		; Grab the EtherType/Length
	xchg al, ah			; Convert big endian to little endian
	cmp ax, 0x0800			; IPv4
	je network_IPv4_handler
	cmp ax, 0x0806			; ARP
	je network_ARP_handler
	cmp ax, 0x86DD			; IPv6
	je network_IPv6_handler

	jmp network_end

network_tx:
	mov byte [os_NetActivity_TX], 1

network_end:
	mov al, 0x20			; Acknowledge the IRQ on the PIC(s)
	cmp byte [os_NetIRQ], 8
	jl network_ack_only_low		; If the network IRQ is less than 8 then the other PIC does not need to be ack'ed
	out 0xA0, al
network_ack_only_low:
	out 0x20, al

	pop rax
	pop rcx
	pop rsi
	pop rdi
	iretq

network_ARP_handler:			; Copy the packet and call the handler
	mov rsi, rdi			; Copy the packet location
	mov rdi, os_eth_temp_buffer	; and copy it here
	push rsi
	push rcx
	rep movsb
	pop rcx
	pop rsi

	; Remove the ARP packet from the ring buffer
;	mov al, byte [os_EthernetBuffer_C2]

	call os_arp_handler		; Handle the packet
	jmp network_end

network_IPv4_handler:
	mov rsi, rdi			; Copy the packet location
	mov rdi, os_eth_temp_buffer	; and copy it here
	push rsi
	push rcx
	rep movsb
	pop rcx
	pop rsi

	mov al, [rsi+0x17]
	cmp al, 0x01			; ICMP
	je network_IPv4_ICMP_handler
	cmp al, 0x06			; TCP
	je network_end
	cmp al, 0x11			; UDP
	je network_end
	jmp network_end

network_IPv4_ICMP_handler:
	push rsi
	mov rsi, network_string02
	call os_print_string
	pop rsi
	call os_icmp_handler
	jmp network_end

network_IPv6_handler:
	jmp network_end

network_string01 db 'ARP!', 0
network_string02 db 'ICMP!', 0
network_string03 db 'TCP!', 0
network_string04 db 'UDP!', 0
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; A simple interrupt that just acknowledges an IPI. Useful for getting an AP past a 'hlt' in the code.
align 16
ap_wakeup:
	push rdi
	push rax

	cld				; Clear direction flag
	mov rdi, [os_LocalAPICAddress]	; Acknowledge the IPI
	add rdi, 0xB0
	xor rax, rax
	stosd

	pop rax
	pop rdi
	iretq				; Return from the IPI.
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Resets a CPU to execute ap_clear
align 16
ap_reset:
	cld				; Clear direction flag
	mov rax, ap_clear		; Set RAX to the address of ap_clear
	mov [rsp], rax			; Overwrite the return address on the CPU's stack
	mov rdi, [os_LocalAPICAddress]	; Acknowledge the IPI
	add rdi, 0xB0
	xor rax, rax
	stosd
	iretq				; Return from the IPI. CPU will execute code at ap_clear
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; Enable an interrupt line
; Expects the interrupt line # in AL
align 16
interrupt_enable:
	push rdx
	push rcx
	push rbx
	push rax
	push rax

	in al, 0x21				; low byte target 0x21
	mov bl, al
	pop rax
	mov dx, 0x21				; Use the low byte pic
	cmp al, 8
	jl interrupt_enable_low
	sub al, 8				; IRQ 8-16
	push rax
	in al, 0xA1				; High byte target 0xA1
	mov bl, al
	pop rax
	mov dx, 0xA1				; Use the high byte pic
interrupt_enable_low:
	mov cl, al
	mov al, 1
	shl al, cl
	not al
	and al, bl
	out dx, al

	pop rax
	pop rbx
	pop rcx
	pop rdx
	ret
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; CPU Exception Gates
align 16
exception_gate_00:
	push rax
	mov al, 0x00
	jmp exception_gate_main

align 16
exception_gate_01:
	push rax
	mov al, 0x01
	jmp exception_gate_main

align 16
exception_gate_02:
	push rax
	mov al, 0x02
	jmp exception_gate_main

align 16
exception_gate_03:
	push rax
	mov al, 0x03
	jmp exception_gate_main

align 16
exception_gate_04:
	push rax
	mov al, 0x04
	jmp exception_gate_main

align 16
exception_gate_05:
	push rax
	mov al, 0x05
	jmp exception_gate_main

align 16
exception_gate_06:
	push rax
	mov al, 0x06
	jmp exception_gate_main

align 16
exception_gate_07:
	push rax
	mov al, 0x07
	jmp exception_gate_main

align 16
exception_gate_08:
	push rax
	mov al, 0x08
	jmp exception_gate_main

align 16
exception_gate_09:
	push rax
	mov al, 0x09
	jmp exception_gate_main

align 16
exception_gate_10:
	push rax
	mov al, 0x0A
	jmp exception_gate_main

align 16
exception_gate_11:
	push rax
	mov al, 0x0B
	jmp exception_gate_main

align 16
exception_gate_12:
	push rax
	mov al, 0x0C
	jmp exception_gate_main

align 16
exception_gate_13:
	push rax
	mov al, 0x0D
	jmp exception_gate_main

align 16
exception_gate_14:
	push rax
	mov al, 0x0E
	jmp exception_gate_main

align 16
exception_gate_15:
	push rax
	mov al, 0x0F
	jmp exception_gate_main

align 16
exception_gate_16:
	push rax
	mov al, 0x10
	jmp exception_gate_main

align 16
exception_gate_17:
	push rax
	mov al, 0x11
	jmp exception_gate_main

align 16
exception_gate_18:
	push rax
	mov al, 0x12
	jmp exception_gate_main

align 16
exception_gate_19:
	push rax
	mov al, 0x13
	jmp exception_gate_main

align 16
exception_gate_main:
	push rbx
	push rdi
	push rsi
	push rax			; Save RAX since os_smp_get_id clobers it
	call os_print_newline
	mov bl, 0x04
	mov rsi, int_string00
	call os_print_string_with_color
	call os_smp_get_id		; Get the local CPU ID and print it
	mov rdi, os_temp_string
	mov rsi, rdi
	call os_int_to_string
	call os_print_string_with_color
	mov rsi, int_string01
	call os_print_string
	mov rsi, exc_string00
	pop rax
	and rax, 0x00000000000000FF	; Clear out everything in RAX except for AL
	push rax
	mov bl, 52
	mul bl				; AX = AL x BL
	add rsi, rax			; Use the value in RAX as an offset to get to the right message
	pop rax
	mov bl, 0x03
	call os_print_string_with_color
	call os_print_newline
	pop rsi
	pop rdi
	pop rbx
	pop rax
	call os_print_newline
	call os_debug_dump_reg
	mov rsi, rip_string
	call os_print_string
	push rax
	mov rax, [rsp+0x08] 	; RIP of caller
	call os_debug_dump_rax
	pop rax
	call os_print_newline
	push rax
	push rcx
	push rsi
	mov rsi, stack_string
	call os_print_string
	mov rsi, rsp
	add rsi, 0x18
	mov rcx, 4
next_stack:
	lodsq
	call os_debug_dump_rax
	mov al, ' '
	call os_print_char
;	call os_print_char
;	call os_print_char
;	call os_print_char
	loop next_stack
	call os_print_newline
	pop rsi
	pop rcx
	pop rax
;	jmp $				; For debugging
	call init_memory_map
	jmp ap_clear			; jump to AP clear code


int_string00 db 'BareMetal OS - CPU ', 0
int_string01 db ' - ', 0
; Strings for the error messages
exc_string db 'Unknown Fatal Exception!', 0
exc_string00 db 'Interrupt 00 - Divide Error Exception (#DE)        ', 0
exc_string01 db 'Interrupt 01 - Debug Exception (#DB)               ', 0
exc_string02 db 'Interrupt 02 - NMI Interrupt                       ', 0
exc_string03 db 'Interrupt 03 - Breakpoint Exception (#BP)          ', 0
exc_string04 db 'Interrupt 04 - Overflow Exception (#OF)            ', 0
exc_string05 db 'Interrupt 05 - BOUND Range Exceeded Exception (#BR)', 0
exc_string06 db 'Interrupt 06 - Invalid Opcode Exception (#UD)      ', 0
exc_string07 db 'Interrupt 07 - Device Not Available Exception (#NM)', 0
exc_string08 db 'Interrupt 08 - Double Fault Exception (#DF)        ', 0
exc_string09 db 'Interrupt 09 - Coprocessor Segment Overrun         ', 0	; No longer generated on new CPU's
exc_string10 db 'Interrupt 10 - Invalid TSS Exception (#TS)         ', 0
exc_string11 db 'Interrupt 11 - Segment Not Present (#NP)           ', 0
exc_string12 db 'Interrupt 12 - Stack Fault Exception (#SS)         ', 0
exc_string13 db 'Interrupt 13 - General Protection Exception (#GP)  ', 0
exc_string14 db 'Interrupt 14 - Page-Fault Exception (#PF)          ', 0
exc_string15 db 'Interrupt 15 - Undefined                           ', 0
exc_string16 db 'Interrupt 16 - x87 FPU Floating-Point Error (#MF)  ', 0
exc_string17 db 'Interrupt 17 - Alignment Check Exception (#AC)     ', 0
exc_string18 db 'Interrupt 18 - Machine-Check Exception (#MC)       ', 0
exc_string19 db 'Interrupt 19 - SIMD Floating-Point Exception (#XM) ', 0
rip_string db ' IP:', 0
stack_string db ' ST:', 0



; =============================================================================
; EOF
