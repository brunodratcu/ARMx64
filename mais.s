.global _start

.section .data
filepath:
    .asciz "/proc/meminfo"

.section .bss
    .align 4
buffer:
    .skip 4096

.section .text
_start:
    // openat(AT_FDCWD, "/proc/meminfo", O_RDONLY, 0)
    mov x0, #-100              // AT_FDCWD
    ldr x1, =filepath
    mov x2, #0                 // O_RDONLY
    mov x3, #0
    mov x8, #56                // syscall: openat
    svc #0

    // guarda fd em x19
    mov x19, x0

    // read(fd, buffer, 4096)
    mov x0, x19
    ldr x1, =buffer
    mov x2, #4096
    mov x8, #63                // syscall: read
    svc #0

    // quantidade lida
    mov x20, x0

    // write(1, buffer, bytes_lidos)
    mov x0, #1                 // stdout
    ldr x1, =buffer
    mov x2, x20
    mov x8, #64                // syscall: write
    svc #0

    // close(fd)
    mov x0, x19
    mov x8, #57                // syscall: close
    svc #0

    // exit(0)
    mov x0, #0
    mov x8, #93                // syscall: exit
    svc #0