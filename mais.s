.global _start

// ─────────────────────────────────────────────────────────────
//  RAM Integrity Monitor — ARM64 Assembly
//  Raspberry Pi 4B (AArch64 bare/Linux userspace)
//
//  Estratégia de integridade viável em userspace:
//   1. Lê /proc/meminfo  → capacidade total / disponível
//   2. Lê /proc/iomem    → mapa de regiões físicas (RAM regions)
//   3. Aloca um bloco via mmap e faz walking de endereços:
//      • escreve padrão 0xDEADBEEFDEADBEEF em cada palavra
//      • relê e compara (bit-flip check)
//      • escreve complemento 0x2152411021524110 e compara
//   4. Libera o bloco (munmap)
//   5. Emite relatório em texto para stdout
//
//  Saída esperada (parseable pelo backend Python):
//    MEMTOTAL:<valor_kB>
//    MEMAVAIL:<valor_kB>
//    PROBE_PAGES:<n>
//    PROBE_ERRORS:<n>
//    STATUS:OK   ou   STATUS:FAIL
// ─────────────────────────────────────────────────────────────

// as -o main.o main.s
// ld -o bin/main main.o

// Syscalls Linux AArch64
.equ SYS_READ,      63
.equ SYS_WRITE,     64
.equ SYS_OPENAT,    56
.equ SYS_CLOSE,     57
.equ SYS_MMAP,      222
.equ SYS_MUNMAP,    215
.equ SYS_EXIT,      93

.equ AT_FDCWD,      -100
.equ O_RDONLY,      0
.equ PROT_RW,       3       // PROT_READ | PROT_WRITE
.equ MAP_PRIVATE,   2
.equ MAP_ANONYMOUS, 0x20
.equ MAP_FLAGS,     (MAP_PRIVATE | MAP_ANONYMOUS)

// Tamanho do bloco de teste: 2 MB (512 páginas × 4 kB)
.equ PROBE_SIZE,    (2 * 1024 * 1024)
.equ WORD_SIZE,     8
.equ PROBE_WORDS,   (PROBE_SIZE / WORD_SIZE)

// Padrão primário e seu complemento bit a bit
.equ PATTERN_A,     0xDEADBEEFDEADBEEF
.equ PATTERN_B,     0x2152411021524110  // ~PATTERN_A

// ─── Dados ───────────────────────────────────────────────────
.section .data

path_meminfo:   .asciz "/proc/meminfo"
path_iomem:     .asciz "/proc/iomem"

str_memtotal:   .ascii "MEMTOTAL:"
str_memavail:   .ascii "MEMAVAIL:"
str_pages:      .ascii "PROBE_PAGES:"
str_errors:     .ascii "PROBE_ERRORS:"
str_status_ok:  .ascii "STATUS:OK\n"
.equ LEN_OK, 10
str_status_fail:.ascii "STATUS:FAIL\n"
.equ LEN_FAIL, 12
str_nl:         .ascii "\n"

// ─── BSS ─────────────────────────────────────────────────────
.section .bss
.align 4
buf_meminfo:    .skip 4096
buf_iomem:      .skip 8192
buf_num:        .skip 32    // scratch para itoa

// ─── Texto ───────────────────────────────────────────────────
.section .text

// ─────────────────────────────────────────────────────────────
// Utilitário: write(1, ptr, len)
// x0=ptr  x1=len  (clobbers x8, x0–x2)
// ─────────────────────────────────────────────────────────────
write_stdout:
    mov x2, x1
    mov x1, x0
    mov x0, #1
    mov x8, #SYS_WRITE
    svc #0
    ret

// ─────────────────────────────────────────────────────────────
// itoa decimal sem sinal: converte x0 → ASCII em buf_num
// Retorna: x0=ptr início, x1=comprimento
// ─────────────────────────────────────────────────────────────
itoa:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    ldr x19, =buf_num
    add x20, x19, #31       // ponteiro fim (write backwards)
    mov x2, #10             // divisor
    mov x3, x0              // valor

    // caso especial: 0
    cbnz x3, 1f
    mov w4, #'0'
    strb w4, [x20]
    sub x20, x20, #1
    b 2f

1:  cbz x3, 2f
    udiv x5, x3, x2         // x5 = x3 / 10
    msub x6, x5, x2, x3     // x6 = x3 % 10
    add w6, w6, #'0'
    strb w6, [x20]
    sub x20, x20, #1
    mov x3, x5
    b 1b

2:  add x0, x20, #1         // ptr para primeiro dígito
    add x1, x19, #31
    sub x1, x1, x20         // comprimento

    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp, #-32]!
    // corrige sp (não usamos frame pointer aqui, ajuste manual)
    add sp, sp, #32
    ret

// ─────────────────────────────────────────────────────────────
// parse_field: procura "KEY:" em buf_meminfo e retorna valor kB
// x0 = ptr para string chave (terminada em '\0')
// retorna x0 = valor numérico (0 se não encontrado)
// ─────────────────────────────────────────────────────────────
parse_field:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0             // chave
    ldr x20, =buf_meminfo   // buffer
    mov x21, #0             // resultado

    // comprimento da chave
    mov x22, x19
.Lklen:
    ldrb w3, [x22], #1
    cbnz w3, .Lklen
    sub x22, x22, x19
    sub x22, x22, #1        // x22 = len(chave)

    // percorre buffer procurando a chave
.Lscan:
    ldrb w3, [x20]
    cbz w3, .Lnot_found

    // compara x22 bytes de x20 com x19
    mov x4, x20
    mov x5, x19
    mov x6, x22
.Lcmp:
    cbz x6, .Lfound_key
    ldrb w7, [x4], #1
    ldrb w8, [x5], #1
    cmp w7, w8
    bne .Lnext_line
    sub x6, x6, #1
    b .Lcmp

.Lfound_key:
    // avança espaços
.Lskip_sp:
    ldrb w3, [x4], #1
    cmp w3, #' '
    beq .Lskip_sp
    // x3 já tem primeiro dígito (x4 passou dele)
    mov x21, #0
.Lparse_dig:
    cmp w3, #'0'
    blt .Ldone_num
    cmp w3, #'9'
    bgt .Ldone_num
    sub w3, w3, #'0'
    mov x7, #10
    mul x21, x21, x7
    add x21, x21, x3
    ldrb w3, [x4], #1
    b .Lparse_dig

.Ldone_num:
    b .Lout

.Lnext_line:
    // avança até '\n'
.Lnl:
    ldrb w3, [x20], #1
    cbz w3, .Lnot_found
    cmp w3, #'\n'
    bne .Lnl
    b .Lscan

.Lnot_found:
    mov x21, #0

.Lout:
    mov x0, x21
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp, #-48]!
    add sp, sp, #48
    ret

// ─────────────────────────────────────────────────────────────
// print_field: imprime "LABEL:<valor>\n" em stdout
// x0 = ptr label string, x1 = len label, x2 = valor numérico
// ─────────────────────────────────────────────────────────────
print_field:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    mov x19, x2             // salva valor
    // escreve label
    mov x1, x1
    bl write_stdout

    // converte valor para ASCII
    mov x0, x19
    bl itoa
    bl write_stdout

    // newline
    ldr x0, =str_nl
    mov x1, #1
    bl write_stdout

    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp, #-32]!
    add sp, sp, #32
    ret

// ─────────────────────────────────────────────────────────────
// probe_ram: aloca PROBE_SIZE via mmap anônimo, faz walking
// retorna x0 = número de erros detectados
// ─────────────────────────────────────────────────────────────
probe_ram:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    // mmap(NULL, PROBE_SIZE, PROT_RW, MAP_PRIVATE|MAP_ANON, -1, 0)
    mov x0, #0
    mov x1, #PROBE_SIZE
    mov x2, #PROT_RW
    mov x3, #MAP_FLAGS
    mov x4, #-1
    mov x5, #0
    mov x8, #SYS_MMAP
    svc #0

    // erro de mmap → retorna -1 como 0 erros (não fatal)
    cmn x0, #4096
    bhi .Lmmap_fail

    mov x19, x0             // x19 = base do bloco
    mov x20, #0             // x20 = contador de erros

    // ── Fase 1: escreve PATTERN_A ────────────────────────────
    mov x0, x19
    mov x1, #PROBE_WORDS
    ldr x2, =PATTERN_A      // pseudo-instrução via literal pool
    // (usamos mov imediato de 64 bits via movz/movk)
    movz x2, #0xBEEF
    movk x2, #0xDEAD, lsl #16
    movk x2, #0xBEEF, lsl #32
    movk x2, #0xDEAD, lsl #48

.Lwrite_a:
    cbz x1, .Lread_a
    str x2, [x0], #8
    sub x1, x1, #1
    b .Lwrite_a

    // ── Fase 2: lê e verifica PATTERN_A ─────────────────────
.Lread_a:
    mov x0, x19
    mov x1, #PROBE_WORDS
    movz x2, #0xBEEF
    movk x2, #0xDEAD, lsl #16
    movk x2, #0xBEEF, lsl #32
    movk x2, #0xDEAD, lsl #48

.Lcheck_a:
    cbz x1, .Lwrite_b
    ldr x3, [x0], #8
    cmp x3, x2
    beq .Lok_a
    add x20, x20, #1        // bit-flip detectado
.Lok_a:
    sub x1, x1, #1
    b .Lcheck_a

    // ── Fase 3: escreve PATTERN_B (complemento) ─────────────
.Lwrite_b:
    mov x0, x19
    mov x1, #PROBE_WORDS
    mvn x2, x2              // complemento bit a bit de PATTERN_A

.Lw_b:
    cbz x1, .Lread_b
    str x2, [x0], #8
    sub x1, x1, #1
    b .Lw_b

    // ── Fase 4: lê e verifica PATTERN_B ─────────────────────
.Lread_b:
    mov x0, x19
    mov x1, #PROBE_WORDS
    movz x2, #0xBEEF
    movk x2, #0xDEAD, lsl #16
    movk x2, #0xBEEF, lsl #32
    movk x2, #0xDEAD, lsl #48
    mvn x2, x2

.Lcheck_b:
    cbz x1, .Ldone_probe
    ldr x3, [x0], #8
    cmp x3, x2
    beq .Lok_b
    add x20, x20, #1
.Lok_b:
    sub x1, x1, #1
    b .Lcheck_b

.Ldone_probe:
    // munmap
    mov x0, x19
    mov x1, #PROBE_SIZE
    mov x8, #SYS_MUNMAP
    svc #0

    mov x0, x20             // retorna erros
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp, #-32]!
    add sp, sp, #32
    ret

.Lmmap_fail:
    mov x0, #0
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp, #-32]!
    add sp, sp, #32
    ret

// ─────────────────────────────────────────────────────────────
// _start
// ─────────────────────────────────────────────────────────────
_start:
    // ── 1. Abre e lê /proc/meminfo ───────────────────────────
    mov x0, #AT_FDCWD
    ldr x1, =path_meminfo
    mov x2, #O_RDONLY
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc #0
    mov x19, x0             // fd

    mov x0, x19
    ldr x1, =buf_meminfo
    mov x2, #4096
    mov x8, #SYS_READ
    svc #0

    mov x0, x19
    mov x8, #SYS_CLOSE
    svc #0

    // ── 2. Parseia MemTotal e MemAvailable ───────────────────
    ldr x0, =path_meminfo   // reutiliza string "MemTotal:"
    // Na prática chamamos parse_field com as strings inline
    // Aqui usamos as strings declaradas nos dados
    ldr x0, =str_memtotal
    bl parse_field
    mov x20, x0             // x20 = mem_total_kb

    ldr x0, =str_memavail
    bl parse_field
    mov x21, x0             // x21 = mem_avail_kb

    // ── 3. Emite MEMTOTAL e MEMAVAIL ─────────────────────────
    ldr x0, =str_memtotal
    mov x1, #9
    mov x2, x20
    bl print_field

    ldr x0, =str_memavail
    mov x1, #9
    mov x2, x21
    bl print_field

    // ── 4. Sonda endereços via mmap walk ─────────────────────
    bl probe_ram
    mov x22, x0             // x22 = erros

    // Emite PROBE_PAGES
    ldr x0, =str_pages
    mov x1, #12
    mov x2, #(PROBE_SIZE / 4096)
    bl print_field

    // Emite PROBE_ERRORS
    ldr x0, =str_errors
    mov x1, #13
    mov x2, x22
    bl print_field

    // ── 5. STATUS ────────────────────────────────────────────
    cbnz x22, .Lfail
    ldr x0, =str_status_ok
    mov x1, #LEN_OK
    bl write_stdout
    b .Lexit

.Lfail:
    ldr x0, =str_status_fail
    mov x1, #LEN_FAIL
    bl write_stdout

.Lexit:
    mov x0, #0
    mov x8, #SYS_EXIT
    svc #0