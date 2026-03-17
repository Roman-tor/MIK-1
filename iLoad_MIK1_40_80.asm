;*********************************************************************
; iLoad - Intel-Hex Loader - FOR CA80 WITH 8251 CARD (MIK1)
; IF TESTING WITH BOOTLOADER -> PAY ATTENTION TO ADDRESS
;           (ADDRESS CONFLICT WITH BOOTLOADER)
; 0E8H IS USED -> USE 0E4H FOR SIO (NEED CUT AND SOLDER)
; https://klonca80.blogspot.com/2024/04/mik1-czyli-sonda-do-miksid-a.html#more
;*********************************************************************
; modyfikacja oruginalu programu /powyzej/ - mozliwosc wyboru wpisu do CA:
; do adresu dodajemy 4000h - jesli wcisniemy 4
; lub 8000h jesli 8 
; musimy to zrobic w ciagu ok. 0,8 sek gdy na wysw. CA pojawi sie napis
; "d   o.  C    A.  o   d"  ; jesli nic nie wcisniemy to zapis do CA wg pliku HEX
; przydatne jesli nasz plik HEX zaczyna sie od 0 - np. MONOTOR CA80
       org #F700
;**************************************************************************
DATA_8251    equ 0E4H    ;Data register on channel A                      *
CONTR_8251   equ 0E5H    ;Control registers on channel A
PRINT        EQU 01D4h ;
obszar:      EQU #FF10 ; tu pocz. dodanego obszaru
;**************************************************************************
;==============================================================================

;  Memory layout:
;
;  +-------+
;  ! $0000 !    not used (area available for loading)
;  !  ---  !
;  ! $FAFF !
;  +-------+
;  ! $FB00 !    iLoad (local data area + program)
;  !  ---  !
;  ! $FF06 !
;  +-------+
;  ! $FF07 !    not used
;  !  ---  !    (reserved for CA80)
;  ! $FFFF !
;  +-------+  
;
; Costants definitions
;
loader_ram      equ    #FB00           ; First RAM location used
eos             equ    #00             ; End of string
cr              equ    #0d             ; Carriage return
lf              equ    #0a             ; Line feed
space           equ    #20             ; Space
;
; iLoad memory starting area
;
; Print a welcome message
  doCA: ; przeslanie pliku HEX z PC do CA80
         ld A, 0
         ld (OBSZAR), A ; default
         ld hl,  ca ; "do.CA.od"
         call    print
         defb    62h
         call op_100ms
         defb 15h
         call 0ffc3h
         cp 8  ; ok. 0,8 sek
         jr z, o8
         cp 4
         jr z, o4
         jr ab
      o4:  ld a, 40h
          jr o8+2
      o8:    ld a,80h
          ld (obszar),a 
          rst 18h
          defb 20h
          call op_100ms
          defb 1
          jr ab+2
                    

ab:       rst 10h
          defb 22h
             CALL    INIT_8251
             CALL    INIT_BUFFER
             ld      hl, hello_msg
             call    puts
             call    crlf
             CALL    FLUSH_TX
                
;
; Load an INTEL-Hex file into memory
;
                call    ih_load         ; Load Intel-Hex file
                ld      a, #ff          ; Test for errors
                cp      h
                jr      nz, print_addr  ; Jump if B<>#FF (no errors)
                cp      l
                jr      nz, print_addr  ; Jump if C<>#FF (no errors)
;
; Print an error message and halt cpu
;               
                ld      hl, ih_load_msg_4
                call    puts
                ld      hl, load_msg_2
                call    puts
                CALL    FLUSH_TX
                RST     30H             ; MONITOR CA80
;                halt
;
; Print starting address
;
print_addr      push    hl              ; Save starting addresss
                ld      hl, ih_load_msg_4
                call    puts
                ld      hl, load_msg_1
                call    puts
                pop     hl              ; Load starting addresss
                call    print_word
                call    crlf
                call    crlf
                CALL    FLUSH_TX
                RST     30H             ; MONITOR CA80              
;******************************************************************************
;***
;*** Subroutines
;***
;******************************************************************************
;
; Load an INTEL-Hex file (a ROM image) into memory. This routine has been 
; more or less stolen from a boot program written by Andrew Lynch and adapted
; to this simple Z80 based machine.
;
; The first address in the INTEL-Hex file is considerd as the Program Starting Address
; and is stored into HL.
;
; If an error is found HL=#FFFF on return.
;
; The INTEL-Hex format looks a bit awkward - a single line contains these 
; parts:
; ':', Record length (2 hex characters), load address field (4 hex characters),
; record type field (2 characters), data field (2 * n hex characters),
; checksum field. Valid record types are 0 (data) and 1 (end of file).
;
; Please note that this routine will not echo what it read from stdin but
; what it "understood". :-)
; 
ih_load         push    af
                push    de
                push    bc
                ld      bc, #ffff       ; Init BC = #FFFF
                ld      hl, ih_load_msg_1
                call    puts
                call    crlf
ih_load_loop    call    getc            ; Get a single character
                cp      cr              ; Don't care about CR
                jr      z, ih_load_loop
                cp      lf              ; ...or LF
                jr      z, ih_load_loop
                cp      space           ; ...or a space
                jr      z, ih_load_loop
                call    to_upper        ; Convert to upper case
                call    putc            ; Echo character
                cp      ':'             ; Is it a colon?                
                jp      nz, ih_load_err ; No - print an error message
                call    get_byte        ; Get record length into A
                ld      d, a            ; Length is now in D
                ld      e, #0           ; Clear checksum
                call    ih_load_chk     ; Compute checksum
                call    get_word        ; Get load address into HL
                ld      a, #ff          ; Save first address as the starting addr
                cp      b
                jr      nz, update_chk  ; Jump if B<>#FF
                cp      c
                jr      nz, update_chk  ; Jump if C<>#FF
                ld      b, h            ; Save starting address in BC
                ld      c, l
update_chk      ld      a, h            ; Update checksum by this address
                call    ih_load_chk
                ld      a, l
                call    ih_load_chk
                call    get_byte        ; Get the record type
                call    ih_load_chk     ; Update checksum
                cp      #1              ; Have we reached the EOF marker?
                jr      nz,ih_load_data1 ; No - get some data
                call    get_byte        ; Yes - EOF, read checksum data
                call    ih_load_chk     ; Update our own checksum
                ld      a, e
                and     a               ; Is our checksum zero (as expected)?
                jr      z, ih_load_exit ; Yes - exit this routine
ih_load_chk_err call    crlf            ; No - print an error message
                ld      hl, ih_load_msg_4
                call    puts
                ld      hl, ih_load_msg_3
                call    puts
                ld      bc, #ffff
                jr      ih_load_exit    ; ...and exit
ih_load_data1
                ;push    bc
                ;ld      bc,8000h        ; przesuniecie, moze byc inna wartosc
                ;add     hl,bc           ; adres w HL z przesuniÄ™ciem
                ;pop     bc              
              ;  ld A, H
              ;  cp 80h
              ;  jr nc, IH_LOAD_DATA
              ;  ld A, 80H
              ;  add A, H
              ;  ld H, A
              ld A, (OBSZAR) ; jesli odczyt pliku HEX jest od 0000 a chcemy 
                             ; zapisac go w CA o=np. od 8000 to <OBSZAR> = 80
                             ; jesli np. od 4000 to 40, jesli OBSZAR = 0 to jak jak plik HEX wskazuje 
              add A, H
              ld H, A
ih_load_data    ld      a, d            ; Record length is now in A
                and     a               ; Did we process all bytes?
                jr      z, ih_load_eol  ; Yes - process end of line
                call    get_byte        ; Read two hex digits into A
                call    ih_load_chk     ; Update checksum
                push    hl              ; Check if HL < iLoad used space
                push    bc
                and     a               ; Reset flag C
                ld      bc, loader_ram  ; BC = iLoad starting area
                sbc     hl, bc          ; HL = HL - iLoad starting area
                pop     bc
                pop     hl
                jr      c,store_byte    ; Jump if HL < iLoad starting area
                call    crlf            ; Print an error message
                ld      hl, ih_load_msg_4
                call    puts
                ld      hl, ih_load_msg_5
                call    puts
                ld      bc, #ffff       ; Set error flag
                jr      ih_load_exit    ; ...and exit
store_byte      ld      (hl), a         ; Store byte into memory
                inc     hl              ; Increment pointer
                dec     d               ; Decrement remaining record length
                jr      ih_load_data    ; Get next byte
ih_load_eol     call    get_byte        ; Read the last byte in the line
                call    ih_load_chk     ; Update checksum
                ld      a, e
                and     a               ; Is the checksum zero (as expected)?
                jr      nz, ih_load_chk_err
                call    crlf
                jp      ih_load_loop    ; Yes - read next line
ih_load_err     call    crlf
                ld      hl, ih_load_msg_4
                call    puts            ; Print error message
                ld      hl, ih_load_msg_2
                call    puts
                ld      bc, #ffff
ih_load_exit    call    crlf
                ld      h, b            ; HL = BC
                ld      l, c
                pop     bc              ; Restore registers
                pop     de
                pop     af
                ret
;
; Compute E = E - A
;
ih_load_chk     push    bc
                ld      c, a            ; All in all compute E = E - A
                ld      a, e
                sub     c
                ld      e, a
                ld      a, c
                pop     bc
                ret

;------------------------------------------------------------------------------
;---
;--- String subroutines
;---
;------------------------------------------------------------------------------

;
; Send a string to the serial line, HL contains the pointer to the string:
;
puts            push    af
                push    hl
puts_loop       ld      a, (hl)
                cp      eos             ; End of string reached?
                jr      z, puts_end     ; Yes
                call    putc
                inc     hl              ; Increment character pointer
                jr      puts_loop       ; Transmit next character
puts_end        pop     hl
                pop     af
                ret
;
; Get a word (16 bit) in hexadecimal notation. The result is returned in HL.
; Since the routines get_byte and therefore get_nibble are called, only valid
; characters (0-9a-f) are accepted.
;
get_word        push    af
                call    get_byte        ; Get the upper byte
                ld      h, a
                call    get_byte        ; Get the lower byte
                ld      l, a
                pop     af
                ret
;
; Get a byte in hexadecimal notation. The result is returned in A. Since
; the routine get_nibble is used only valid characters are accepted - the 
; input routine only accepts characters 0-9a-f.
;
get_byte        push    bc              ; Save contents of B (and C)
                call    get_nibble      ; Get upper nibble
                rlc     a
                rlc     a
                rlc     a
                rlc     a
                ld      b, a            ; Save upper four bits
                call    get_nibble      ; Get lower nibble
                or      b               ; Combine both nibbles
                pop     bc              ; Restore B (and C)
                ret
;
; Get a hexadecimal digit from the serial line. This routine blocks until
; a valid character (0-9a-f) has been entered. A valid digit will be echoed
; to the serial line interface. The lower 4 bits of A contain the value of 
; that particular digit.
;
get_nibble      call    getc            ; Read a character
                call    to_upper        ; Convert to upper case
                call    is_hex          ; Was it a hex digit?
                jr      nc, get_nibble  ; No, get another character
                call    nibble2val      ; Convert nibble to value
                call    print_nibble
                ret
;
; is_hex checks a character stored in A for being a valid hexadecimal digit.
; A valid hexadecimal digit is denoted by a set C flag.
;
is_hex          cp      'G'             ; Greater than 'F'?
                ret     nc              ; Yes
                cp      '0'             ; Less than '0'?
                jr      nc, is_hex_1    ; No, continue
                ccf                     ; Complement carry (i.e. clear it)
                ret
is_hex_1        cp      ':'             ; Less or equal '9*?
                ret     c               ; Yes
                cp      'A'             ; Less than 'A'?
                jr      nc, is_hex_2    ; No, continue
                ccf                     ; Yes - clear carry and return
                ret
is_hex_2        scf                     ; Set carry
                ret
;
; Convert a single character contained in A to upper case:
;
to_upper        cp      'a'             ; Nothing to do if not lower case
                ret     c
                cp      '{'             ; > 'z'?
                ret     nc              ; Nothing to do, either
                and     #5f             ; Convert to upper case
                ret
;
; Expects a hexadecimal digit (upper case!) in A and returns the
; corresponding value in A.
;
nibble2val      cp      ':'             ; Is it a digit (less or equal '9')?
                jr      c, nibble2val_1 ; Yes
                sub     7               ; Adjust for A-F
nibble2val_1    sub     '0'             ; Fold back to 0..15
                and     #f              ; Only return lower 4 bits
                ret
;
; Print_nibble prints a single hex nibble which is contained in the lower 
; four bits of A:
;
print_nibble    push    af              ; We won't destroy the contents of A
                and     #f              ; Just in case...
                add     a, '0'          ; If we have a digit we are done here.
                cp      ':'             ; Is the result > 9?
                jr      c, print_nibble_1
                add     a,7             ; Take care of A-F
print_nibble_1  call    putc            ; Print the nibble and
                pop     af              ; restore the original value of A
                ret
;
; Send a CR/LF pair:
;
crlf            push    af
                ld      a, cr
                call    putc
                ld      a, lf
                call    putc
                pop     af
                ret
;
; Print_word prints the four hex digits of a word to the serial line. The 
; word is expected to be in HL.
;
print_word      push    hl
                push    af
                ld      a, h
                call    print_byte
                ld      a, l
                call    print_byte
                pop     af
                pop     hl
                ret
;
; Print_byte prints a single byte in hexadecimal notation to the serial line.
; The byte to be printed is expected to be in A.
;
print_byte      push    af              ; Save the contents of the registers
                push    bc
                ld      b, a
                rrca
                rrca
                rrca
                rrca
                call    print_nibble    ; Print high nibble
                ld      a, b
                call    print_nibble    ; Print low nibble
                pop     bc              ; Restore original register contents
                pop     af
                ret

;------------------------------------------------------------------------------
;---
;--- I/O subroutines
;---
;------------------------------------------------------------------------------

;
; Send a single character to the serial line (A contains the character):
;
putc            
                LD      (SAVE_CHAR),A   ; instead of PUSH AF
                CALL    CHECK_TX        ; try to send char from buffer
                CALL    write_buffer    ; put new char in buffer
                RET
;
; Wait for a single incoming character on the serial line
; and read it, result is in A:
;
getc    
                CALL    CHECK_TX        ; try to send char from buffer
                CALL    READ_CHAR       ; is new char?
                JR      Z,GETC          ; repeat if not
                RET                     ; in A new char
                
;************************************************************************
;*              I8251A INIT                                             *
;*      SEE RADIOELEKTRONIK 1/1994                                      *
;************************************************************************
INIT_8251:
     XOR  A
     OUT  (CONTR_8251),A
     OUT  (CONTR_8251),A
     OUT  (CONTR_8251),A
     LD   A,40H              ;RESET
     OUT  (CONTR_8251),A
     LD   A,4EH              ;8 BIT, 1 STOP, X16
     OUT  (CONTR_8251),A
     IN   A,(DATA_8251)   ;FLUSH
     IN   A,(DATA_8251)
     LD   A,07H              ;RST=1, DTR=0, Rx Tx ON
     OUT  (CONTR_8251),A
     RET

;************************************************************************
;*              I8251A READ CHAR                                        *
;************************************************************************
READ_CHAR:              
     IN   A,(CONTR_8251)
     AND  02H             ; Rx ready? 
     RET  Z               ; return if not
     IN   A,(DATA_8251)   ; read new char
     RET

;************************************************************************
;*              I8251A SEND CHAR                                        *
;************************************************************************

; Z80 Ring Buffer with Empty/Full Check Example

; Constants
;BUFFER_SIZE  equ 16    ; Define the size of the buffer
BUFFER_START equ 0FBH   ; Start address of the buffer in memory

; Buffer initialization
init_buffer:
    XOR     A            ; Initialize the write and read pointers
    LD      IX,write_ptr
    LD      (IX+0),A      ; write_ptr
    LD      (IX+1),A      ; read_ptr
    ret

CHECK_TX:
    IN        A,(CONTR_8251)
    AND       01H
    RET       Z               ; return if Tx not ready
    CALL    read_buffer
    OR      A
    RET     Z               ; return if buffer is empty
    OUT       (DATA_8251),A   ; send char
     RET

FLUSH_TX:
    CALL    is_buffer_empty
    RET     Z               ; return if buffer is empty
    CALL    CHECK_TX        ; try to send char from buffer
    JR      FLUSH_TX        ; repeat

; Check if the buffer is empty
is_buffer_empty:
    LD      A,(IX+0)      ; write_ptr
    CP      (IX+1)        ; read_ptr
    ret                   ; Zero flag is set if buffer is empty

; Check if the buffer is full
is_buffer_full:
    LD      A,(IX+0)      ; Get the current write pointer
    inc     a             ; Move to the next position
    CP      (IX+1)        ; read_ptr
    ret                   ; Zero flag is set if buffer is full

; Write data to the buffer with full check
write_buffer:
    call    is_buffer_full ; Check if the buffer is full
    RET     Z           ; buffer_full   ; If the Zero flag is set, the buffer is full

    ; Write data (assuming SAVE_CHAR holds the data to write)
    PUSH    HL
    ld      H, BUFFER_START
    LD      L,(IX+0)        ; Get the current write pointer
    LD      A,(SAVE_CHAR)   ; put new char in buffer
    ld      (hl), a         ; Write the data
    POP     HL
    ; Increment the write pointer
    INC     (IX+0)          ; Move to the next position
    ret

buffer_full:
    ; Handle the error case (e.g., return without writing)
    ;ret

; Read data from the buffer with empty check
read_buffer:
    call    is_buffer_empty     ; Check if the buffer is empty
    JR      Z, buffer_empty     ; If the Zero flag is set, the buffer is empty

    ; Read data
    PUSH    HL
    ld      H, BUFFER_START
    LD      L,(IX+1)            ; Get the current read pointer
    ld      A,(hl)              ; Read the data
    POP     HL
    ; Increment the read pointer
    INC     (IX+1)              ; Move to the next position
    ret

buffer_empty:
    ; Handle the empty case (e.g., return without reading)
    XOR     A
    ret 
    ;  opóŸnienia
 op_2ms:
  EX (sp), hl
  ld e, (hl)
  inc hl
  ex (sp), hl
 op_1:
  halt
  dec e
  jr nz, op_1
  ret

op_100ms:; opóŸn. x 0,1s+ podaæ param. /cd xx yy zz/
  EX (sp), hl    ; zz - wielkoœæ opóznienia
  ld a, (hl)
  inc hl
  ex (sp), hl
  push hl
  ld l,a
 op_licz:
  call op_2ms
   defb 32h ; to jest parametr 32h=50x2ms=100ms /0,1 sek/
  dec l
  jr nz, op_licz
  pop hl
  ret

      
; Variables
write_ptr:   defb 0      ; Write pointer (offset from BUFFER_START)
read_ptr:    defb 0      ; Read pointer (offset from BUFFER_START)
SAVE_CHAR:
    defb 0FFH
; Message definitions
;
hello_msg       defm   "iLoad - Intel-Hex Loader - for CA80", eos
load_msg_1      defm   "Starting Address: ", eos
load_msg_2      defm   "Load error - System halted", eos
ih_load_msg_1   defm   "CA80 czeka na dane...", eos
ih_load_msg_2   defm   "Syntax error!", eos
ih_load_msg_3   defm   "Checksum error!", eos 
ih_load_msg_4   defm   "iLoad: ", eos
ih_load_msg_5   defm   "kolizja adresu!", eos
; komunilaty na CA     d   o.  C    A.  o   d   
ca:             defb  #5E,#DC,#39,#F7, #5C, #DE, 255; przesyl z PC do CA
                                 
   ;################################################
   ;##   po ostatnim bajcie naszego programu wpisujemy DD E2 - nazwa programu
   ;################################################
 defb 0DDh, 0E2h; marker nazwy
 defm  " MIK1 do CA odx8x4",255      ; nazwa programu, max 16 znakÃ³w /dla LCD 4x 20 znakow w linii/
 ;defb 0FFH                   ; koniec tekstu
; koniec zabawy. :-)
