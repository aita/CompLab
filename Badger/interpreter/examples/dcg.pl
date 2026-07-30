% A calculator, as a grammar.
%
% The point of a DCG is that a grammar rule and a predicate are the same
% thing.  `expr(V) --> term(V0), rest(V0, V)` is read as a clause with two
% extra arguments, the input before and the input after, and the parser that
% comes out is the recursive descent parser you would have written -- except
% that backtracking is already there, so an ambiguous grammar simply yields
% more than one parse.

:- initialization(main).

% ------------------------------------------------------------------ scanning

% The input is a list of character codes, which is what "..." reads as.
ws --> [C], { code_type(C, space) }, !, ws.
ws --> [].

% ----------------------------------------------------------------- the grammar

% Left recursion would not terminate -- the one thing a DCG cannot have -- so
% the usual trick applies: consume one operand, then a tail.
expr(V)    --> term(V0), expr_tail(V0, V).
expr_tail(Acc, V) --> ws, "+", !, term(N), { Acc1 is Acc + N }, expr_tail(Acc1, V).
expr_tail(Acc, V) --> ws, "-", !, term(N), { Acc1 is Acc - N }, expr_tail(Acc1, V).
expr_tail(V, V)   --> [].

term(V)    --> factor(V0), term_tail(V0, V).
term_tail(Acc, V) --> ws, "*", !, factor(N), { Acc1 is Acc * N }, term_tail(Acc1, V).
term_tail(Acc, V) --> ws, "/", !, factor(N), { N =\= 0, Acc1 is Acc / N }, term_tail(Acc1, V).
term_tail(V, V)   --> [].

factor(V)  --> ws, "(", !, expr(V), ws, ")".
factor(V)  --> ws, "-", !, factor(V0), { V is -V0 }.
factor(V)  --> ws, number(V).

number(V)  --> digits(Ds), { Ds \== [], digits_value(Ds, 0, V) }.
digits([D|Ds]) --> [D], { code_type(D, digit(_)) }, !, digits(Ds).
digits([])     --> [].

digits_value([], V, V).
digits_value([D|Ds], Acc, V) :-
    code_type(D, digit(W)),
    Acc1 is Acc * 10 + W,
    digits_value(Ds, Acc1, V).

% --------------------------------------------------- the same grammar, as a tree

% Nothing says a DCG has to compute a value.  Building a term instead gives an
% abstract syntax tree, and the two grammars differ only in the braces.
tree(T)    --> tree_term(T0), tree_tail(T0, T).
tree_tail(L, T) --> ws, "+", !, tree_term(R), tree_tail(L + R, T).
tree_tail(L, T) --> ws, "-", !, tree_term(R), tree_tail(L - R, T).
tree_tail(T, T) --> [].

tree_term(T) --> tree_factor(T0), tree_term_tail(T0, T).
tree_term_tail(L, T) --> ws, "*", !, tree_factor(R), tree_term_tail(L * R, T).
tree_term_tail(L, T) --> ws, "/", !, tree_factor(R), tree_term_tail(L / R, T).
tree_term_tail(T, T) --> [].

tree_factor(T) --> ws, "(", !, tree(T), ws, ")".
tree_factor(-T) --> ws, "-", !, tree_factor(T).
tree_factor(N) --> ws, number(N).

% --------------------------------------------------------------- generating

% Nothing says the input has to be known.  Given an open list, the same
% nonterminal enumerates the strings it accepts, because the goals inside it
% run in that direction too.
bits([])     --> [].
bits([B|Bs]) --> [B], { member(B, [0,1]) }, bits(Bs).

% -------------------------------------------------------------------- driving

calculate(Text, Value) :-
    phrase(expr(Value), Text, Rest),
    phrase(ws, Rest, []).

parse(Text, Tree) :-
    phrase(tree(Tree), Text, Rest),
    phrase(ws, Rest, []).

try(Text) :-
    atom_codes(Atom, Text),
    ( calculate(Text, Value) -> Shown = Value ; Shown = 'no parse' ),
    ( parse(Text, Tree) -> Structure = Tree ; Structure = '-' ),
    format("~q~t~14|~w~t~26|~q~n", [Atom, Shown, Structure]).

main :-
    format("~w~t~14|~w~t~26|~w~n", ['input', 'value', 'tree']),
    forall(member(Text, ["1+2*3", "(1+2)*3", " 2 * -3 ", "10/4", "1+", "42"]),
           try(Text)),
    nl,

    findall(Bs, (length(Codes, 3), phrase(bits(Bs), Codes)), All),
    format("every three-bit string bits//1 accepts:~n  ~q~n", [All]).
