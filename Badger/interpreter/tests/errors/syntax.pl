% A clause the reader cannot make sense of.  Loading reports it, skips to the
% next clause, and keeps the exit status.
good(1).
broken(X) :- X = .
good(2).
