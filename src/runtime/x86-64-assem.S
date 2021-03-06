/*
 * very-low-level utilities for runtime support
 */

/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#ifdef __ELF__
// Mark the object as not requiring an executable stack.
.section .note.GNU-stack,"",%progbits
#endif

#define LANGUAGE_ASSEMBLY
#include "genesis/config.h"
#include "validate.h"
#include "sbcl.h"
#include "genesis/closure.h"
#include "genesis/fdefn.h"
#include "genesis/static-symbols.h"
#include "genesis/thread.h"
	
/* Minimize conditionalization for different OS naming schemes. */
#if defined __linux__  || defined LISP_FEATURE_FREEBSD || defined __OpenBSD__ || defined __NetBSD__ || defined __sun || defined _WIN64 || defined __DragonFly__
#define GNAME(var) var
#else
#define GNAME(var) _##var
#endif

#if POSITION_INDEPENDENT_ASM
#define PIC_CALL(x) x@PLT
#define PIC_VAR(x) x(%rip)
#else
#define PIC_CALL(x) x
#define PIC_VAR(x) x
#endif

/* Get the right type of alignment. Linux, FreeBSD and OpenBSD
 * want alignment in bytes. */
#if defined(__linux__) || defined(LISP_FEATURE_FREEBSD) || defined(__OpenBSD__) || defined __NetBSD__ || defined(__sun) || defined _WIN64 || defined(__DragonFly__)
#define align_4byte	4
#define align_8byte	8
#define align_16byte	16
#define align_32byte	32
#define align_page	32768
#else
#define	align_4byte	2
#define	align_8byte	3
#define	align_16byte	4	
#define	align_page	15
#endif			

/*
 * The assembler used for win32 doesn't like .type or .size directives,
 * so we want to conditionally kill them out. So let's wrap them in macros
 * that are defined to be no-ops on win32. Hopefully this still works on
 * other platforms.
 */
#if !defined(LISP_FEATURE_WIN32) && !defined(LISP_FEATURE_DARWIN)
#define TYPE(name) .type name,@function
#define SIZE(name) .size name,.-name
#define DOLLAR(name) $(name)
#else
#define TYPE(name)
#define SIZE(name)
#endif

/*
 * x86/darwin (as of MacOS X 10.4.5) doesn't reliably fire signal
 * handlers (SIGTRAP or Mach exception handlers) for 0xCC, wo we have
 * to use ud2 instead. ud2 is an undefined opcode, #x0b0f, or
 * 0F 0B in low-endian notation, that causes SIGILL to fire. We check
 * for this instruction in the SIGILL handler and if we see it, we
 * advance the EIP by two bytes to skip over ud2 instruction and
 * call sigtrap_handler. */
#if defined(LISP_FEATURE_UD2_BREAKPOINTS)
#define TRAP ud2
#else
#define TRAP int3
#endif

/*
 * More Apple assembler hacks
 */

#if defined(LISP_FEATURE_DARWIN)
/* global symbol x86-64 sym(%rip) hack:*/
#define GSYM(name) name(%rip)
#else
#define GSYM(name) $name
#endif

        
	.text
        .globl  GNAME(all_threads)
        
	.text	
	.globl  GNAME(call_into_lisp_first_time)
	TYPE(GNAME(call_into_lisp_first_time))
		
/* We don't worry too much about saving registers 
 * here, because we never expect to return from the initial call to lisp 
 * anyway */
	
	.align	align_16byte,0x90
GNAME(call_into_lisp_first_time):
	push	%rbp		# Save old frame pointer.
	mov	%rsp,%rbp	# Establish new frame.
#if defined(LISP_FEATURE_DARWIN)
	movq    GSYM(GNAME(all_threads)),%rax
#else
        movq    PIC_VAR(GNAME(all_threads)),%rax
#endif
	mov     THREAD_CONTROL_STACK_END_OFFSET(%rax) ,%rsp
	jmp     Lstack

	.text	
	.globl  GNAME(call_into_lisp)
	TYPE(GNAME(call_into_lisp))
		
/*
 * amd64 calling convention: C expects that
 * arguments go in rdi rsi rdx rcx r8 r9
 * return values in rax rdx
 * callee saves rbp rbx r12-15 if it uses them
 */
#ifdef LISP_FEATURE_WIN32
# define SUPPORT_FOMIT_FRAME_POINTER
#endif
	.align	align_16byte,0x90
GNAME(call_into_lisp):
#ifdef SUPPORT_FOMIT_FRAME_POINTER
	mov	%rbp,%rax
#endif
	push	%rbp		# Save old frame pointer.
	mov	%rsp,%rbp	# Establish new frame.
Lstack:
#ifdef SUPPORT_FOMIT_FRAME_POINTER
	/* If called through call_into_lisp_first_time, %r15 becomes invalid
	 * here, but we will not return in that case. */
	push	%r15
	mov	%rax,%r15
#endif
	/* FIXME x86 saves FPU state here */
	push	%rbx  	# these regs are callee-saved according to C
	push	%r12	# so must be preserved and restored when 
	push	%r13    # the lisp function returns
	push	%r14    #
	push	%r15    #

	mov	%rsp,%rbx	# remember current stack
	push	%rbx		# Save entry stack on (maybe) new stack.

	push	%rdi	# args from C
	push	%rsi	#
	push	%rdx	#
#ifdef LISP_FEATURE_SB_THREAD
# ifdef SUPPORT_FOMIT_FRAME_POINTER
	mov	(%rbp),%rcx
	sub	$32,%rsp
	call	GNAME(carry_frame_pointer)
	add	$32,%rsp
	mov	%rax,(%rbp)
# endif
#ifdef LISP_FEATURE_GCC_TLS
	movq	%fs:0, %rax
	movq	GNAME(current_thread)@TPOFF(%rax), %r12
#else
#ifdef LISP_FEATURE_DARWIN
	mov	GSYM(GNAME(specials)),%rdi
#else
	mov	PIC_VAR(specials),%rdi
#endif
	call    PIC_CALL(GNAME(pthread_getspecific))
	mov	%rax,%r12
#endif
#endif
	pop	%rcx	# num args
	pop	%rbx	# arg vector
	pop	%rax	# function ptr/lexenv

	xor	%rdx,%rdx	# clear any descriptor registers 
	xor	%rdi,%rdi	# that we can't be sure we'll 
	xor	%rsi,%rsi	# initialise properly.  XX do r8-r15 too?
	cmp	$0,%rcx
        # It's tempting to think 'cmov' for these assignments, but don't:
        # cmov does a memory cycle whether or not it moves, succumbing to
        # a classic buffer overrun bug if argv[] is "badly" placed.
	je	Ldone
	mov	0(%rbx),%rdx	# arg0
	cmp	$1,%rcx
	je	Ldone
	mov	8(%rbx),%rdi	# arg1
	cmp	$2,%rcx
	je	Ldone
	mov	16(%rbx),%rsi	# arg2
Ldone:
	shl	$(N_FIXNUM_TAG_BITS),%rcx	# (fixnumize num-args)
	/* Registers rax, rcx, rdx, rdi, and rsi are now live. */
	xor	%rbx,%rbx	# available

	/* Alloc new frame. */
	push	%rbp            # Dummy for return address
	push	%rbp		# fp in save location S1
	mov	%rsp,%rbp	# The current sp marks start of new frame.

Lcall:
	call	*CLOSURE_FUN_OFFSET(%rax)
	
	/* If the function returned multiple values, the carry flag will be set.
           Lose them */
	jnc	LsingleValue	
	mov	%rbx, %rsp
LsingleValue:	

/* Restore the stack, in case there was a stack change. */
	pop	%rsp		# c-sp

/* Restore C regs */
	pop	%r15
	pop	%r14
	pop	%r13
	pop	%r12
	pop	%rbx

/* FIXME Restore the NPX state. */

	mov	%rdx,%rax	# c-val
#ifdef SUPPORT_FOMIT_FRAME_POINTER
	mov	%r15,%rbp	# orig rbp
	pop	%r15		# orig r15
	add	$8,%rsp		# no need for saved (overridden) rbp
#else
	leave
#endif
	ret
	SIZE(GNAME(call_into_lisp))

#ifdef LISP_FEATURE_SB_THREAD
	.text	
	.globl  GNAME(funcall_alien_callback)
	TYPE(GNAME(funcall_alien_callback))
	.align	align_16byte,0x90
GNAME(funcall_alien_callback):
/* Specialized call_into_lisp for callbacks
   rdi arg1
   rsi arg2
   rdx arg0
   rcx thread
*/
        
	push	%rbp		# Save old frame pointer.
	mov	%rsp,%rbp	# Establish new frame.

	push	%rbx  	# these regs are callee-saved according to C
	push	%r12	# so must be preserved and restored when 
	push	%r13    # the lisp function returns
	push	%r14    #
	push	%r15    #

        mov     %rcx,%r12
        mov     $(3 << N_FIXNUM_TAG_BITS),%rcx

	/* Alloc new frame. */
        push	%rbp            # Dummy for return address
	push	%rbp		# fp in save location S1
        mov	%rsp,%rbp
        mov     (ENTER_ALIEN_CALLBACK_FDEFN+FDEFN_FUN_OFFSET),%rax
	call	*CLOSURE_FUN_OFFSET(%rax)

/* Restore C regs */
	pop	%r15
	pop	%r14
	pop	%r13
	pop	%r12
	pop	%rbx

	leave

	ret
	SIZE(GNAME(funcall_alien_callback))
#endif
 

/* Our call-site does not take care of caller-saved xmm registers, so it
 * falls to us spill them beforing hopping into C.
 *
 * We simply save all of them.
 *
 * (But for the sake of completeness, here is my understanding of the specs:)
 *                     System V       Microsoft
 * argument passing    xmm0-7         xmm0-3
 * caller-saved        xmm8-15        xmm4-5
 * callee-saved        -              xmm6-15
 *
 *  --DFL */

#define stkxmmsave(n) movaps %xmm##n, n*16(%rsp)
#define stkxmmload(n) movaps n*16(%rsp), %xmm##n
#define map_all_xmm(op) \
	op(0);op(1);op(2);op(3);op(4);op(5);op(6);op(7); \
    op(8);op(9);op(10);op(11);op(12);op(13);op(14);op(15);

#define push_regs_a_c_d_si_di_8_9_10 \
 push %rax; push %rcx; push %rdx; push %rsi; push %rdi; push %r8; push %r9; push %r10
#define pop_regs_10_9_8_di_si_d_c_a \
 pop %r10; pop %r9; pop %r8; pop %rdi; pop %rsi; pop %rdx; pop %rcx; pop %rax
        
	.text
	.align	align_16byte,0x90
	.globl  GNAME(alloc_tramp)
	TYPE(GNAME(alloc_tramp))
GNAME(alloc_tramp):
	cld
	push	%rbp		# Save old frame pointer.
	mov	%rsp,%rbp	# Establish new frame.
	and	$-32,%rsp
	sub	$16*16,%rsp
	map_all_xmm(stkxmmsave)
	# Doing rax twice is to maintain 16-byte stack alignment.
	push    %rax
	push_regs_a_c_d_si_di_8_9_10
	push	%r11
	# r12 through r15 are callee-saved
	mov	16(%rbp),%rdi
	call	GNAME(alloc)
	mov	%rax,16(%rbp)
	pop	%r11
	pop_regs_10_9_8_di_si_d_c_a
	pop	%rax # corresponds to "extra" push
	map_all_xmm(stkxmmload)
	mov	%rbp,%rsp
	pop	%rbp
	ret
	SIZE(GNAME(alloc_tramp))


	.align	align_16byte,0x90
	.globl  GNAME(alloc_to_r11)
	TYPE(GNAME(alloc_to_r11))
GNAME(alloc_to_r11):
	cld
	push	%rbp		# Save old frame pointer.
	mov	%rsp,%rbp	# Establish new frame.
	and	$-32,%rsp
	sub	$16*16,%rsp
	map_all_xmm(stkxmmsave)
	push_regs_a_c_d_si_di_8_9_10
	# r12 through r15 are callee-saved
	mov	16(%rbp),%rdi
	call	GNAME(alloc)
	mov	%rax,%r11       # move to result register
	pop_regs_10_9_8_di_si_d_c_a
	map_all_xmm(stkxmmload)
	mov	%rbp,%rsp
	pop	%rbp
	retq    $8              # remove 8 bytes from the stack
	SIZE(GNAME(alloc_to_r11))

/*
 * fun-end breakpoint magic
 */

/*
 * For an explanation of the magic involved in function-end
 * breakpoints, see the implementation in ppc-assem.S.
 */

	.text
	.globl 	GNAME(fun_end_breakpoint_guts)
	.align	align_16byte
GNAME(fun_end_breakpoint_guts):
	/* Multiple Value return */
	jc	multiple_value_return
	/* Single value return: The eventual return will now use the
	   multiple values return convention but with a return values
	   count of one. */
	mov	%rsp,%rbx	# Setup ebx - the ofp.
	sub	$8,%rsp		# Allocate one stack slot for the return value
	mov	$(1 << N_FIXNUM_TAG_BITS),%rcx		# Setup ecx for one return value.
	mov	GSYM(NIL),%rdi	# default second value
	mov	GSYM(NIL),%rsi	# default third value
multiple_value_return:
	
	.globl  GNAME(fun_end_breakpoint_trap)
	.align	align_16byte,0x90
GNAME(fun_end_breakpoint_trap):
	TRAP
	.byte 	trap_FunEndBreakpoint
	hlt			# We should never return here.

	.globl  GNAME(fun_end_breakpoint_end)
GNAME(fun_end_breakpoint_end):


	.globl 	GNAME(do_pending_interrupt)
	TYPE(GNAME(do_pending_interrupt))
	.align	align_16byte,0x90
GNAME(do_pending_interrupt):
	TRAP
	.byte 	trap_PendingInterrupt
	ret
	SIZE(GNAME(do_pending_interrupt))

	.globl	GNAME(post_signal_tramp)
	TYPE(GNAME(post_signal_tramp))
	.align	align_16byte,0x90
GNAME(post_signal_tramp):
	/* this is notionally the second half of a function whose first half
 	 * doesn't exist.  This is where call_into_lisp returns when called 
	 * using return_to_lisp_function */
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %r11
	popq %r10
	popq %r9
	popq %r8
	popq %rdi
	popq %rsi
        /* skip RBP and RSP */
	popq %rbx
	popq %rdx
	popq %rcx
	popq %rax
        popfq
	leave
	ret
	SIZE(GNAME(post_signal_tramp))

/* When LISP_FEATURE_C_STACK_IS_CONTROL_STACK, we cannot safely scrub
 * the control stack from C, largely due to not knowing where the
 * active stack frame ends.  On such platforms, we reimplement the
 * core scrubbing logic in assembly, in this case here:
 */
	.text
	.align	align_16byte,0x90
	.globl GNAME(arch_scrub_control_stack)
	TYPE(GNAME(arch_scrub_control_stack))
GNAME(arch_scrub_control_stack):
	/* We are passed three parameters:
	 * A (struct thread *) in RDI,
	 * the address of the guard page in RSI, and
	 * the address of the hard guard page in RDX.
	 * We may trash RAX, RCX, and R8-R11 with impunity.
	 * [RSP] is our return address, [RSP-8] is the first
	 * stack slot to scrub. */

	/* We start by setting up our scrub pointer in RAX, our
	 * guard page upper bound in R8, and our hard guard
	 * page upper bound in R9. */
	lea	-8(%rsp), %rax
#ifdef LISP_FEATURE_DARWIN
	mov	GSYM(GNAME(os_vm_page_size)),%r9
#else
	mov	PIC_VAR(os_vm_page_size),%r9
#endif
	lea	(%rsi,%r9), %r8
	lea	(%rdx,%r9), %r9

	/* Now we begin our main scrub loop. */
ascs_outer_loop:

	/* If we're about to scrub the hard guard page, exit. */
	cmp	%r9, %rax
	jae	ascs_check_guard_page
	cmp	%rax, %rdx
	jbe	ascs_finished

ascs_check_guard_page:
	/* If we're about to scrub the guard page, and the guard
	 * page is protected, exit. */
	cmp	%r8, %rax
	jae	ascs_clear_loop
	cmp	%rax, %rsi
	ja	ascs_clear_loop
	cmpq	$(NIL), THREAD_CONTROL_STACK_GUARD_PAGE_PROTECTED_OFFSET(%rdi)
	jne	ascs_finished

	/* Clear memory backwards to the start of the (4KiB) page */
ascs_clear_loop:
	movq	$0, (%rax)
	test	$0xfff, %rax
	lea	-8(%rax), %rax
	jnz	ascs_clear_loop

	/* If we're about to hit the hard guard page, exit. */
	cmp	%r9, %rax
	jae	ascs_finished

	/* If the next (previous?) 4KiB page contains a non-zero
	 * word, continue scrubbing. */
ascs_check_loop:
	testq	$-1, (%rax)
	jnz	ascs_outer_loop
	test	$0xfff, %rax
	lea	-8(%rax), %rax
	jnz	ascs_check_loop

ascs_finished:
	ret
	SIZE(GNAME(arch_scrub_control_stack))
