import { createContext } from "react";

// node id -> the compiler's complaints about it.  The canvas reads this to
// outline the offending nodes while you edit.
export const ErrorContext = createContext<Map<string, string[]>>(new Map());

export const portKey = (node: string, port: string) => `${node} ${port}`;

// Every input port that has an edge in it.  A port that has none shows a field
// to type a number into instead.
export const ConnectedContext = createContext<Set<string>>(new Set());
