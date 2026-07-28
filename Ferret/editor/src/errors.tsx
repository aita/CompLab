import { createContext } from "react";

// node id -> the compiler's complaints about it.  The canvas reads this to
// outline the offending nodes while you edit.
export const ErrorContext = createContext<Map<string, string[]>>(new Map());
