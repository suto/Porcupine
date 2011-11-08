; =============================================================================
; BareMetal -- a 64-bit OS written in Assembly for x86-64 systems
; Copyright (C) 2008-2011 Return Infinity -- see LICENSE.TXT
;
; PCI Functions. http://wiki.osdev.org/PCI
; =============================================================================

align 16
db 'DEBUG: PCI      '
align 16


; -----------------------------------------------------------------------------
; os_pci_read_reg -- Read a register from a PCI device
;  IN:	BL  = Bus number
;	CL  = Device/Slot number
;	DL  = Register number
; OUT:	EAX = Register information
;	All other registers preserved
os_pci_read_reg:
	push rdx
	push rcx
	push rbx

	shl ebx, 16			; Move Bus number to bits 23 - 16
	shl ecx, 11			; Move Device number to bits 15 - 11
	mov bx, cx
	shl edx, 2
	mov bl, dl
	and ebx, 0x00ffffff		; Clear bits 31 - 24
	or ebx, 0x80000000		; Set bit 31
	mov eax, ebx
	mov dx, PCI_CONFIG_ADDRESS
	out dx, eax
	mov dx, PCI_CONFIG_DATA
	in eax, dx

	pop rbx
	pop rcx
	pop rdx
ret
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; os_pci_find_device -- Finds a PCI device based on the Device and Vendor ID provided
;  IN:	EAX = Device and Vendor ID (ie: 0x70008086)
; OUT:	BL  = Bus number (8-bit value)
;	CL  = Device/Slot number (5-bit value)
;	Carry set if no matching device was found
;	All other registers preserved
os_pci_find_device:
	push rdx

	mov rbx, rax			; Save device and vendor IDs to RBX
	xor rcx, rcx
	xor rax, rax
	
	mov ecx, 0x80000000		; Bit 31 must be set

os_pci_find_device_check_next:
	mov eax, ecx
	mov dx, PCI_CONFIG_ADDRESS
	out dx, eax
	mov dx, PCI_CONFIG_DATA
	in eax, dx			; EAX now holds the Device and Vendor ID
	cmp eax, ebx
	je os_pci_find_device_found
	add ecx, 0x800
	cmp ecx, 0x81000000		; The end has been reached (already looked at 8192 devices)
	jne os_pci_find_device_check_next

os_pci_find_device_not_found:
	stc				; Set carry (failure)
	jmp os_pci_find_device_end

os_pci_find_device_found:		; ECX bits 23 - 16 is the Bus # and bits 15 - 11 is the Device/Slot #
	xor rax, rax
	xor rbx, rbx
	shr ecx, 11			; Device/Slot number is now bits 4 - 0
	mov bl, cl			; BL contains Device/Slot number
	and bl, 00011111b		; Clear the top 3 bits, BL contains the Device/Slot number
	shr ecx, 5			; Bus number is now bits 7 - 0
	mov al, cl			; AL contains the Bus number
	xor ecx, ecx
	mov cl, bl
	mov bl, al
	clc				; Clear carry (success)

os_pci_find_device_end:
	pop rdx
	ret
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; os_pci_dump_devices -- Dump all Device and Vendor ID's to the screen
;  IN:	Nothing
; OUT:	Nothing, All registers preserved
; http://pci-ids.ucw.cz/read/PC/ - Online list of Device and Vendor ID's
os_pci_dump_devices:
	push rdx
	push rcx
	push rbx
	push rax

	xor rcx, rcx
	xor rax, rax
	
	mov ecx, 0x80000000		; Bit 31 must be set

os_pci_dump_devices_check_next:
	mov eax, ecx
	mov dx, PCI_CONFIG_ADDRESS
	out dx, eax
	mov dx, PCI_CONFIG_DATA
	in eax, dx			; EAX now holds the Device and Vendor ID
	cmp eax, 0xffffffff		; 0xFFFFFFFF means no device present on that Bus and Slot
	je os_pci_dump_devices_nothing_there
	call os_debug_dump_eax		; Print the Device and Vendor ID (DDDDVVVV)
	call os_print_newline
os_pci_dump_devices_nothing_there:
	add ecx, 0x800
	cmp ecx, 0x81000000		; The end has been reached (already looked at 8192 devices)
	jne os_pci_dump_devices_check_next

os_pci_dump_devices_end:
	pop rax
	pop rbx
	pop rcx
	pop rdx
ret
; -----------------------------------------------------------------------------


;Configuration Mechanism One has two IO port rages associated with it.
;The address port (0xcf8-0xcfb) and the data port (0xcfc-0xcff).
;A configuration cycle consists of writing to the address port to specify which device and register you want to access and then reading or writing the data to the data port.

PCI_CONFIG_ADDRESS	EQU	0x0CF8
PCI_CONFIG_DATA		EQU	0x0CFC

;ddress dd 10000000000000000000000000000000b
;          /\     /\      /\   /\ /\    /\
;        E    Res    Bus    Dev  F  Reg   0
; Bits
; 31		Enable bit = set to 1
; 30 - 24	Reserved = set to 0
; 23 - 16	Bus number = 256 options
; 15 - 11	Device/Slot number = 32 options
; 10 - 8	Function number = will leave at 0 (8 options)
; 7 - 2		Register number = will leave at 0 (64 options) 64 x 4 bytes = 256 bytes worth of accessible registers
; 1 - 0		Set to 0


; =============================================================================
; EOF
