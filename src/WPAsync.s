// Trampolines for calling Swift async functions from C (Swift async calling convention:
// async context in x22, self in x20, indirect results as leading arguments).
// clang 18 crashes when compiling swiftasynccall + musttail, so these are written by hand.

    .text
    .p2align 2

// Entry of the task created by WPStartAsyncCall: called by the Swift runtime with
// x0 = result buffer (Void, unused), x20 = closure context, x22 = this task's initial context.
// C fills in the callee's arguments; then the callee is tail-called like Swift code does.
    .globl _WPAsyncEntry
_WPAsyncEntry:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #64
    mov x0, x22
    mov x1, x20
    mov x2, sp
    bl _WPAsyncPrepare          // fills [sp]: x0 x1 x2 x3 x4 x20 x22 fn
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldr x4, [sp, #32]
    ldr x20, [sp, #40]
    ldr x22, [sp, #48]
    ldr x16, [sp, #56]
    add sp, sp, #64
    ldp x29, x30, [sp], #16
    br x16

// Resume function given to the callee (its context's ResumeParent). x22 = the callee's
// context (or ours). C delivers the result and frees the callee context; then this task
// finishes by tail-calling its own ResumeParent with x22 = its context and x20 = no error.
    .globl _WPAsyncResume
_WPAsyncResume:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #16
    mov x0, x22
    mov x1, sp
    bl _WPAsyncFinish           // fills [sp]: context, resume function
    ldr x22, [sp, #0]
    ldr x16, [sp, #8]
    mov x20, xzr
    add sp, sp, #16
    ldp x29, x30, [sp], #16
    br x16
