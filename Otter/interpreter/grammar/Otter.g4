grammar Otter;

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

program
    : moduleDeclaration importDeclaration* topLevelDeclaration* EOF
    ;

moduleDeclaration
    : 'module' Identifier ';'
    ;

importDeclaration
    : 'import' Identifier ';'
    ;

topLevelDeclaration
    : structDeclaration
    | functionDeclaration
    | globalVariableDeclaration
    | typeAliasDeclaration
    ;

typeAliasDeclaration
    : 'export'? 'type' Identifier '=' type ';'
    ;

structDeclaration
    : 'export'? 'struct' Identifier '{' structField* '}'
    ;

structField
    : Identifier ':' type ';'
    ;

functionDeclaration
    : 'export'? 'fun' Identifier parameterList '->' type functionBody
    ;

// A body-less function is a binding to something the host provides.
functionBody
    : block
    | ';'
    ;

globalVariableDeclaration
    : 'export'? 'var' Identifier ':' type '=' expression ';'
    ;

parameterList
    : '(' (parameter (',' parameter)*)? ')'
    ;

parameter
    : Identifier ':' type
    ;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type
    : '*' type                                                      # pointerType
    | 'fun' '(' (type (',' type)*)? ')' '->' type                   # functionType
    | qualifiedName ('<' type (',' type)* '>')?                     # namedType
    ;

qualifiedName
    : Identifier ('.' Identifier)*
    ;

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

block
    : '{' statement* '}'
    ;

statement
    : variableDeclaration
    | nestedFunctionDeclaration
    | returnStatement
    | ifStatement
    | whileStatement
    | forStatement
    | breakStatement
    | continueStatement
    | expressionStatement
    | block
    ;

// A function declared inside another. It is neither exported nor body-less, so
// it does not reuse the top-level rule.
nestedFunctionDeclaration
    : 'fun' Identifier parameterList '->' type block
    ;

variableDeclaration
    : 'var' Identifier ':' type '=' expression ';'
    ;

returnStatement
    : 'return' expression? ';'
    ;

ifStatement
    : 'if' '(' expression ')' block ('else' elseBody)?
    ;

elseBody
    : ifStatement
    | block
    ;

whileStatement
    : 'while' '(' expression ')' block
    ;

// Each of the three parts may be left out; an absent condition never ends the
// loop.
forStatement
    : 'for' '(' forInitializer? ';' condition=expression? ';' step=expression? ')' block
    ;

forInitializer
    : 'var' Identifier ':' type '=' expression
    | expression
    ;

breakStatement
    : 'break' ';'
    ;

continueStatement
    : 'continue' ';'
    ;

expressionStatement
    : expression ';'
    ;

// ---------------------------------------------------------------------------
// Expressions
//
// Alternatives are ordered from tightest to loosest binding; ANTLR reads that
// order as the precedence table.
// ---------------------------------------------------------------------------

expression
    : expression '(' (expression (',' expression)*)? ')'    # callExpression
    | expression '[' expression ']'                         # indexExpression
    | expression '.' Identifier                             # fieldExpression
    | op=('+' | '-' | '!' | '~' | '*' | '&') expression     # unaryExpression
    | expression 'as' type                                  # castExpression
    | expression op=('*' | '/' | '%') expression            # multiplicativeExpression
    | expression op=('+' | '-') expression                  # additiveExpression
    | expression op=('<' | '<=' | '>' | '>=') expression    # relationalExpression
    | expression op=('==' | '!=') expression                # equalityExpression
    | expression '&&' expression                            # logicalAndExpression
    | expression '||' expression                            # logicalOrExpression
    | <assoc=right> expression '=' expression               # assignmentExpression
    | IntegerLiteral                                        # integerExpression
    | FloatingLiteral                                       # floatingExpression
    | StringLiteral                                         # stringExpression
    | CharLiteral                                           # charExpression
    | 'true'                                                # trueExpression
    | 'false'                                               # falseExpression
    | 'null'                                                # nullExpression
    | Identifier                                            # nameExpression
    | '(' expression ')'                                    # groupExpression
    | arrayLiteral                                          # arrayExpression
    | structLiteral                                         # structExpression
    | anonymousFunction                                     # functionExpression
    | ifExpression                                          # conditionalExpression
    ;

// An if that stands for a value. Both arms are needed, and each ends in the
// expression it yields.
ifExpression
    : 'if' '(' expression ')' valueBlock 'else' (ifExpression | valueBlock)
    ;

valueBlock
    : '{' statement* expression '}'
    ;

// Either the elements one by one, or a single element repeated a given number
// of times.
arrayLiteral
    : '[' (expression (';' expression | (',' expression)*))? ']'
    ;

structLiteral
    : 'new' qualifiedName '{' (structInitializer (',' structInitializer)*)? '}'
    ;

structInitializer
    : Identifier ':' expression
    ;

anonymousFunction
    : 'fun' parameterList '->' type block
    ;

// ---------------------------------------------------------------------------
// Tokens
//
// Type names are deliberately absent: `int`, `string` and the rest are plain
// identifiers that the initial type environment happens to bind.
// ---------------------------------------------------------------------------

Module      : 'module';
Import      : 'import';
Export      : 'export';
Struct      : 'struct';
Fun         : 'fun';
Var         : 'var';
Type        : 'type';
Return      : 'return';
If          : 'if';
Else        : 'else';
While       : 'while';
For         : 'for';
Break       : 'break';
Continue    : 'continue';
New         : 'new';
As          : 'as';
True        : 'true';
False       : 'false';
Null        : 'null';

Identifier
    : [a-zA-Z_] [a-zA-Z_0-9]*
    ;

IntegerLiteral
    : '0x' [0-9a-fA-F] [0-9a-fA-F_]*
    | '0b' [01] [01_]*
    | [0-9] [0-9_]*
    ;

FloatingLiteral
    : [0-9] [0-9_]* '.' [0-9] [0-9_]* Exponent?
    | [0-9] [0-9_]* Exponent
    ;

fragment Exponent
    : [eE] [+-]? [0-9]+
    ;

StringLiteral
    : '"' (~["\\\r\n] | Escape)* '"'
    ;

CharLiteral
    : '\'' (~['\\\r\n] | Escape) '\''
    ;

fragment Escape
    : '\\' ['"?\\abfnrtv0]
    | '\\x' [0-9a-fA-F] [0-9a-fA-F]
    | '\\u' '{' [0-9a-fA-F]+ '}'
    ;

LineComment
    : '//' ~[\r\n]* -> skip
    ;

BlockComment
    : '/*' .*? '*/' -> skip
    ;

Whitespace
    : [ \t\r\n]+ -> skip
    ;
