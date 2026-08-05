/** <module> What the allocator and the emitter both have to agree about.
 *
 *  x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
 *  linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
 *  call in a caller-saved register, so x16 is allocatable like any other; x17
 *  is the one register kept back, for an address the emitter has to compute
 *  after allocation is over.  x18 is the platform register, x29 the frame
 *  pointer, x30 the link register.
 */

:- module(registers,
          [ caller_saved/1, callee_saved/1, argument_regs/1, scratch/1,
            whole_machine/1,      % -Machine
            limited/2,            % +MaxRegs, -Machine
            anywhere/2,           % +Machine, -Colours
            register_count/2,     % +Machine, -Count
            machine_caller/2      % +Machine, -Colours
          ]).

caller_saved([9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8]).
callee_saved([19, 20, 21, 22, 23, 24, 25, 26, 27, 28]).
argument_regs([0, 1, 2, 3, 4, 5, 6, 7]).
scratch([17]).

whole_machine(machine(Caller, Callee)) :-
    caller_saved(Caller), callee_saved(Callee).

machine_caller(machine(Caller, _), Caller).

anywhere(machine(Caller, Callee), Colours) :- append(Caller, Callee, Colours).

register_count(machine(Caller, Callee), Count) :-
    length(Caller, A), length(Callee, B), Count is A + B.

%!  limited(+MaxRegs, -Machine) is det.
%
%   A smaller machine, so that the spiller can be tested on small programs.

limited(MaxRegs, machine(Caller, Callee)) :-
    callee_saved(AllCallee), caller_saved(AllCaller),
    Half is max(2, MaxRegs // 2),
    take(AllCallee, Half, Callee),
    length(Callee, N),
    Rest is max(1, MaxRegs - N),
    take(AllCaller, Rest, Caller).

take(List, N, Taken) :-
    length(List, Len),
    Count is min(N, Len),
    length(Taken, Count),
    append(Taken, _, List).
