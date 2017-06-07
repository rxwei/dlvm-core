//
//  Parse.swift
//  DLVM
//
//  Copyright 2016-2017 Richard Wei.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

/// This file contains a hand-written LL parser with reasonably fine-tuned 
/// diagnostics. The parser entry is `Parser.parseModule`.

import CoreTensor
import DLVM

/// Table storing definitions for parsing
private struct SymbolTable {
    var locals: [String : Value] = [:]
    var globals: [String : Value] = [:]
    var nominalTypes: [String : Type] = [:]
    var basicBlocks: [String : BasicBlock] = [:]
}

/// Main parser of textual DLVM IR
public class Parser {
    public let tokens: [Token]
    fileprivate lazy var restTokens: ArraySlice<Token> = ArraySlice(self.tokens)
    fileprivate var symbolTable = SymbolTable()

    public init(tokens: [Token]) {
        self.tokens = tokens
    }

    public init(text: String) throws {
        let lexer = Lexer(text: text)
        tokens = try lexer.performLexing()
    }
}

private extension Parser {

    var currentToken: Token? {
        guard let first = restTokens.first else { return nil }
        return first
    }

    var nextToken: Token? {
        return restTokens.dropFirst().first
    }

    var currentLocation: SourceLocation? {
        return currentToken?.range.lowerBound
    }

    var isEOF: Bool {
        return restTokens.isEmpty
    }

    @discardableResult
    func consumeToken() -> Token {
        return restTokens.removeFirst()
    }

    func consume(if predicate: (TokenKind) throws -> Bool) rethrows {
        guard let token = currentToken else { return }
        if try predicate(token.kind) {
            consumeToken()
        }
    }

    func consume(while predicate: (TokenKind) throws -> Bool) rethrows {
        while let first = currentToken, try predicate(first.kind) {
            consumeToken()
        }
    }

    @discardableResult
    func consumeIfAny(_ tokenKind: TokenKind) -> Token? {
        if let tok = currentToken, tok.kind == tokenKind {
            return restTokens.removeFirst()
        }
        return nil
    }

    @discardableResult
    func consume(_ tokenKind: TokenKind) throws -> Token {
        guard let first = restTokens.first else {
            throw ParseError.unexpectedEndOfInput(expected: String(describing: tokenKind))
        }
        guard first.kind == tokenKind else {
            throw ParseError.unexpectedToken(expected: String(describing: tokenKind), first)
        }
        return restTokens.removeFirst()
    }

    @discardableResult
    func consumeOrDiagnose(_ expected: String) throws -> Token {
        guard currentToken != nil else {
            throw ParseError.unexpectedEndOfInput(expected: expected)
        }
        return consumeToken()
    }

    @discardableResult
    func withPeekedToken<T>(_ expected: String, _ execute: (Token) throws -> T?) throws -> T {
        let tok = try peekOrDiagnose(expected)
        guard let result = try execute(tok) else {
            throw ParseError.unexpectedToken(expected: expected, tok)
        }
        return result
    }
    
    @discardableResult
    func peekOrDiagnose(_ expected: String) throws -> Token {
        guard let tok = currentToken else {
            throw ParseError.unexpectedEndOfInput(expected: expected)
        }
        return tok
    }

    func parseInteger() throws -> (Int, SourceRange) {
        let name: String = "an integer"
        let tok = try consumeOrDiagnose(name)
        switch tok.kind {
        case let .integer(i): return (i, tok.range)
        default: throw ParseError.unexpectedToken(expected: name, tok)
        }
    }

    func parseDataType() throws -> (DataType, SourceRange) {
        let name: String = "a data type"
        let tok = try consumeOrDiagnose(name)
        switch tok.kind {
        case let .dataType(dt): return (dt, tok.range)
        default: throw ParseError.unexpectedToken(expected: name, tok)
        }
    }

    func parseIdentifier(ofKind kind: IdentifierKind, isDefinition: Bool = false) throws -> (String, Token) {
        let tok = try consumeOrDiagnose("an identifier")
        let name: String
        switch tok.kind {
        case .identifier(kind, let id): name = id
        default: throw ParseError.unexpectedIdentifierKind(kind, tok)
        }
        /// If we are parsing a name definition, check for its uniqueness
        let contains: (String) -> Bool
        switch kind {
        case .basicBlock: contains = symbolTable.basicBlocks.keys.contains
        case .global: contains = symbolTable.globals.keys.contains
        case .temporary: contains = symbolTable.locals.keys.contains
        case .type: contains = symbolTable.nominalTypes.keys.contains
        default: return (name, tok)
        }
        if isDefinition && contains(name) {
            throw ParseError.redefinedIdentifier(tok)
        }
        return (name, tok)
    }

    @discardableResult
    func withBacktracking<T>(_ execute: () throws -> T?) rethrows -> T? {
        let originalTokens = restTokens
        guard let result = try execute() else {
            restTokens = originalTokens
            return nil
        }
        return result
    }

    func withPreservedState(execute: () throws -> ()) {
        let originalTokens = restTokens
        _ = try? execute()
        restTokens = originalTokens
    }

    @discardableResult
    func consumeWrappablePunctuation(_ punct: Punctuation) throws -> Token {
        consumeAnyNewLines()
        let tok = try consume(.punctuation(punct))
        consumeAnyNewLines()
        return tok
    }

    func consumeStringLiteral() throws -> String {
        let tok = try consumeOrDiagnose("a string literal")
        guard case let .stringLiteral(str) = tok.kind else {
            throw ParseError.unexpectedToken(expected: "a string literal", tok)
        }
        return str
    }

    func consumeAnyNewLines() {
        consume(while: {$0 == .newLine})
    }

    func consumeOneOrMore(_ kind: TokenKind) throws {
        try consume(kind)
        consume(while: { $0 == kind })
    }

    /// Parse one or more with optional backtracking
    /// - Note: In the closure, return `nil` to backtrack
    func parseMany<T>(_ parseElement: () throws -> T?) rethrows -> [T] {
        var elements: [T] = []
        while let result = try withBacktracking(parseElement) {
            elements.append(result)
        }
        return elements
    }

    /// Parse one or more with optional backtracking
    /// - Note: In the first closure, return `nil` to backtrack
    func parseMany<T>(_ parseElement: () throws -> T?, unless: ((Token) -> Bool)? = nil,
                      separatedBy parseSeparator: () throws -> ()) rethrows -> [T] {
        guard let tok = currentToken else { return [] }
        if let unless = unless, unless(tok) { return [] }
        guard let first = try withBacktracking(parseElement) else { return [] }
        var elements: [T] = []
        while let _ = withBacktracking({try? parseSeparator()}),
            let result = try withBacktracking(parseElement) {
            elements.append(result)
        }
        return [first] + elements
    }
}

extension Parser {
    /// Parse uses separated by ','
    func parseUseList(in basicBlock: BasicBlock?, unless: (Token) -> Bool) throws -> [Use] {
        return try parseMany({ try parseUse(in: basicBlock).0 },
                             separatedBy: { try self.consumeWrappablePunctuation(.comma) })
    }

    /// Parse a literal
    func parseLiteral(in basicBlock: BasicBlock?) throws -> (Literal, SourceRange) {
        let tok = try consumeOrDiagnose("a literal")
        switch tok.kind {
        /// Float
        case let .float(f):
            return (.scalar(.float(f)), tok.range)
        /// Integer
        case let .integer(i):
            return (.scalar(.int(i)), tok.range)
        /// Boolean `true`
        case .keyword(.true):
            return (.scalar(.bool(true)), tok.range)
        /// Boolean `false`
        case .keyword(.false):
            return (.scalar(.bool(false)), tok.range)
        /// `null`
        case .keyword(.null):
            return (.null, tok.range)
        /// `undefined`
        case .keyword(.undefined):
            return (.undefined, tok.range)
        /// `zero`
        case .keyword(.zero):
            return (.zero, tok.range)
        /// Array
        case .punctuation(.leftSquareBracket):
            let elements = try parseUseList(in: basicBlock,
                                            unless: { $0.kind == .punctuation(.rightSquareBracket) })
            try consumeWrappablePunctuation(.rightSquareBracket)
            return (.array(elements), tok.range)
        /// Tuple
        case .punctuation(.leftParenthesis):
            let elements = try parseUseList(in: basicBlock,
                                            unless: { $0.kind == .punctuation(.rightParenthesis) })
            try consumeWrappablePunctuation(.rightParenthesis)
            return (.tuple(elements), tok.range)
        /// Tensor
        case .punctuation(.leftAngleBracket):
            let elements = try parseUseList(in: basicBlock,
                                            unless: { $0.kind == .punctuation(.rightAngleBracket) })
            try consumeWrappablePunctuation(.rightAngleBracket)
            return (.tensor(elements), tok.range)
        /// Struct
        case .punctuation(.leftCurlyBracket):
            let fields: [(String, Use)] = try parseMany({
                let (key, _) = try parseIdentifier(ofKind: .key)
                try consumeWrappablePunctuation(.equal)
                let (val, _) = try parseUse(in: basicBlock)
                return (key, val)
            }, unless: { tok in
                tok.kind == .punctuation(.rightCurlyBracket)
            }, separatedBy: {
                try self.consumeWrappablePunctuation(.comma)
            })
            let rightBkt = try consumeWrappablePunctuation(.rightCurlyBracket)
            return (.struct(fields), tok.startLocation..<rightBkt.endLocation)
        default:
            throw ParseError.unexpectedToken(expected: "a literal", tok)
        }
    }

    /// Parse a shape
    func parseNonScalarShape() throws -> (TensorShape, SourceRange) {
        let (first, firstRange) = try parseInteger()
        var dims = [first]
        var lastLoc = firstRange.upperBound
        while let dim: Int = try withBacktracking({
            try consumeWrappablePunctuation(.times)
            /// If following 'x' isn't an integer, backtrack
            guard let (num, range) = try? parseInteger() else { return nil }
            lastLoc = range.upperBound
            return num
        }) { dims.append(dim) }
        return (TensorShape(dims), firstRange.lowerBound..<lastLoc)
    }

    func parseElementKey(in basicBlock: BasicBlock?) throws -> (ElementKey, SourceRange) {
        return try withPeekedToken("an element key", { tok in
            consumeToken()
            switch tok.kind {
            case let .integer(i):
                return (.index(i), tok.range)
            case let .identifier(.key, nameKey):
                return (.name(nameKey), tok.range)
            default:
                let (val, range) = try parseUse(in: basicBlock)
                return (.value(val), range)
            }
        })
    }

    func parseType() throws -> (Type, SourceRange) {
        let tok = try consumeOrDiagnose("a type")
        switch tok.kind {
        /// Void
        case .keyword(.void):
            return (.void, tok.range)
        /// Scalar
        case .dataType(let dt):
            return (.tensor([], dt), tok.range)
        /// Array
        case .punctuation(.leftSquareBracket):
            let (count, _) = try parseInteger()
            try consumeWrappablePunctuation(.times)
            let (elementType, _) = try parseType()
            let rightBkt = try consume(.punctuation(.rightSquareBracket))
            return (.array(count, elementType), tok.startLocation..<rightBkt.endLocation)
        /// Tensor
        case .punctuation(.leftAngleBracket):
            let (shape, _) = try parseNonScalarShape()
            try consumeWrappablePunctuation(.times)
            let (dt, _) = try parseDataType()
            let rightBkt = try consume(.punctuation(.rightAngleBracket))
            return (.tensor(shape, dt), tok.startLocation..<rightBkt.endLocation)
        /// Tuple
        case .punctuation(.leftParenthesis):
            let elementTypes = try parseMany({
                try parseType().0
            }, unless: { tok in
                tok.kind == .punctuation(.rightParenthesis)
            }, separatedBy: {
                try self.consumeWrappablePunctuation(.comma)
            })
            let rightBkt = try consume(.punctuation(.rightParenthesis))
            /// Check for any hint of function type
            if let tok = withBacktracking({try? consumeWrappablePunctuation(.rightArrow)}) {
                let (retType, retRange) = try parseType()
                return (.function(elementTypes, retType), tok.startLocation..<retRange.upperBound)
            }
            return (.tuple(elementTypes), tok.startLocation..<rightBkt.endLocation)
        /// Nominal type
        case .identifier(.type, let typeName):
            guard let type = symbolTable.nominalTypes[typeName] else {
                throw ParseError.undefinedNominalType(tok)
            }
            return (type, tok.range)
        /// Pointer
        case .punctuation(.star):
            let (pointeeType, range) = try parseType()
            return (.pointer(pointeeType), tok.startLocation..<range.upperBound)
        default:
            throw ParseError.unexpectedToken(expected: "a type", tok)
        }
    }

    func parseTypeSignature() throws -> (Type, SourceRange) {
        try consume(.punctuation(.colon))
        consumeAnyNewLines()
        return try parseType()
    }

    func parseUse(in basicBlock: BasicBlock?) throws -> (Use, SourceRange) {
        let tok = try peekOrDiagnose("a use of value")
        let use: Use
        let range: SourceRange
        switch tok.kind {
        /// Identifier
        case let .identifier(kind, id):
            consumeToken()
            /// Either a global or a local
            let maybeVal: Value?
            switch kind {
            case .global: maybeVal = symbolTable.globals[id]
            case .temporary: maybeVal = symbolTable.locals[id]
            default: throw ParseError.unexpectedIdentifierKind(kind, tok)
            }
            guard let val = maybeVal else {
                throw ParseError.undefinedIdentifier(tok)
            }
            use = val.makeUse()
            let (type, typeSigRange) = try parseTypeSignature()
            range = tok.startLocation..<typeSigRange.upperBound
            guard type == use.type else {
                throw ParseError.typeMismatch(expected: use.type, range)
            }
        /// Anonymous local identifier in a basic block
        case let .anonymousIdentifier(bbIndex, instIndex):
            guard let bb = basicBlock else {
                throw ParseError.anonymousIdentifierNotInLocal(tok)
            }
            consumeToken()
            let function = bb.parent
            /// Criteria for identifier index:
            /// - BB referred to must precede the current BB
            /// - Instruction referred to must precede the current instruction
            guard bbIndex <= function.endIndex else {
                throw ParseError.invalidAnonymousIdentifierIndex(tok)
            }
            let refBB = bbIndex == function.endIndex ? bb : function[bbIndex]
            guard refBB.indices.contains(instIndex) else {
                throw ParseError.invalidAnonymousIdentifierIndex(tok)
            }
            let inst = refBB[instIndex]
            /// This value cannot be named, or have void type
            guard inst.name == nil, inst.type != .void else {
                throw ParseError.undefinedIdentifier(tok)
            }
            /// Now we can use this value
            use = %inst
            let (type, typeSigRange) = try parseTypeSignature()
            range = tok.startLocation..<typeSigRange.upperBound
            guard type == use.type else {
                throw ParseError.typeMismatch(expected: use.type, range)
            }
        /// Literal
        case .float(_), .integer(_), .keyword(.true), .keyword(.false),
             .punctuation(.leftAngleBracket),
             .punctuation(.leftCurlyBracket),
             .punctuation(.leftSquareBracket),
             .punctuation(.leftParenthesis):
            let (lit, _) = try parseLiteral(in: basicBlock)
            let (type, typeSigRange) = try parseTypeSignature()
            range = tok.startLocation..<typeSigRange.upperBound
            use = .literal(type, lit)
        default:
            throw ParseError.unexpectedToken(expected: "a use of value", tok)
        }
        return (use, range)
    }

    func parseInstructionKind(in basicBlock: BasicBlock?) throws -> InstructionKind {
        let opcode: InstructionKind.Opcode = try withPeekedToken("an opcode") { tok in
            guard case let .opcode(opcode) = tok.kind else {
                return nil
            }
            consumeToken()
            return opcode
        }
        /// - todo: parse instruction kind
        switch opcode {
        /// 'branch' <bb> '(' (<val> (',' <val>)*)? ')'
        case .branch:
            let (bbName, bbTok) = try parseIdentifier(ofKind: .basicBlock)
            guard let bb = symbolTable.basicBlocks[bbName] else {
                throw ParseError.undefinedIdentifier(bbTok)
            }
            try consume(.punctuation(.leftParenthesis))
            let args = try parseUseList(in: basicBlock,
                                        unless: { $0.kind == .punctuation(.rightParenthesis) })
            try consume(.punctuation(.rightParenthesis))
            return .branch(bb, args)

        /// 'conditional' <cond> 'then' <bb> '(' (<val> (',' <val>)*)? ')'
        ///                      'else' <bb> '(' (<val> (',' <val>)*)? ')'
        case .conditional:
            let (cond, _) = try parseUse(in: basicBlock)
            /// Then
            try consume(.keyword(.then))
            let (thenBBName, thenBBTok) = try parseIdentifier(ofKind: .basicBlock)
            guard let thenBB = symbolTable.basicBlocks[thenBBName] else {
                throw ParseError.undefinedIdentifier(thenBBTok)
            }
            try consume(.punctuation(.leftParenthesis))
            let thenArgs = try parseUseList(in: basicBlock,
                                            unless: { $0.kind == .punctuation(.rightParenthesis) })
            try consume(.punctuation(.rightParenthesis))
            /// Else
            try consume(.keyword(.else))
            let (elseBBName, elseBBTok) = try parseIdentifier(ofKind: .basicBlock)
            guard let elseBB = symbolTable.basicBlocks[elseBBName] else {
                throw ParseError.undefinedIdentifier(elseBBTok)
            }
            try consume(.punctuation(.leftParenthesis))
            let elseArgs = try parseUseList(in: basicBlock,
                                            unless: { $0.kind == .punctuation(.rightParenthesis) })
            try consume(.punctuation(.rightParenthesis))
            return .conditional(cond, thenBB, thenArgs, elseBB, elseArgs)
            
        /// 'return' <val>?
        case .return:
            if case .newLine? = currentToken?.kind {
                return .return(nil)
            }
            return .return(try parseUse(in: basicBlock).0)

        /// 'dataTypeCast' <val> 'to' <data_type>
        case .dataTypeCast:
            let (srcVal, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.to))
            let (dtype, _) = try parseDataType()
            return .dataTypeCast(srcVal, dtype)
            
        /// 'scan' <val> 'by' <func|assoc_op> 'along' <num> (',' <num>)*
        case .scan:
            let (val, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.by))
            let combinator: ReductionCombinator = try withPeekedToken("a function or an associative operator", { tok in
                switch tok.kind {
                case .identifier(_):
                    return try .function(parseUse(in: basicBlock).0)
                case .opcode(.binaryOp(.associative(let op))):
                    return .op(op)
                default:
                    return nil
                }
            })
            try consume(.keyword(.along))
            let (firstDim, _) = try parseInteger()
            let restDims: [Int] = try parseMany({
                try consumeWrappablePunctuation(.comma)
                return try parseInteger().0
            })
            return .scan(combinator, val, [firstDim] + restDims)

        /// 'reduce' <val> 'by' <func|assoc_op> 'along' <num> (',' <num>)*
        case .reduce:
            let (val, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.by))
            let combinator: ReductionCombinator = try withPeekedToken("a function or an associative operator", { tok in
                switch tok.kind {
                case .identifier(_):
                    return try .function(parseUse(in: basicBlock).0)
                case .opcode(.binaryOp(.associative(let op))):
                    return .op(op)
                default:
                    return nil
                }
            })
            try consume(.keyword(.along))
            let (firstDim, _) = try parseInteger()
            let restDims: [Int] = try parseMany({
                try consumeWrappablePunctuation(.comma)
                return try parseInteger().0
            })
            return .reduce(combinator, val, [firstDim] + restDims)

        /// 'matrixMultiply' <val> ',' <val>
        case .matrixMultiply:
            let (lhs, _) = try parseUse(in: basicBlock)
            try consumeWrappablePunctuation(.comma)
            let (rhs, _) = try parseUse(in: basicBlock)
            return .matrixMultiply(lhs, rhs)
            
        /// 'concatenate' <val> (',' <val>)* along <num>
        case .concatenate:
            let (firstVal, _) = try parseUse(in: basicBlock)
            let restVals: [Use] = try parseMany({
                try consumeWrappablePunctuation(.comma)
                return try parseUse(in: basicBlock).0
            })
            try consume(.keyword(.along))
            let (axis, _) = try parseInteger()
            return .concatenate([firstVal] + restVals, axis: axis)

        /// 'transpose' <val>
        case .transpose:
            return try .transpose(parseUse(in: basicBlock).0)

        /// 'shapeCast' <val> 'to' <shape>
        case .shapeCast:
            let (val, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.to))
            let shape: TensorShape = try withPeekedToken("dimensions separated by 'x', or 'scalar'", { tok in
                switch tok.kind {
                case .keyword(.scalar):
                    return .scalar
                case .integer(_):
                    return try parseNonScalarShape().0
                default:
                    return nil
                }
            })
            return .shapeCast(val, shape)
            
        /// 'bitCast' <val> 'to' <type>
        case .bitCast:
            let (val, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.to))
            let (type, _) = try parseType()
            return .bitCast(val, type)
            
        /// 'extract' <num|key|val> (',' <num|key|val>)* 'from' <val>
        case .extract:
            let keys: [ElementKey] = try parseMany({
                try parseElementKey(in: basicBlock).0
            }, separatedBy: {
                try consumeWrappablePunctuation(.comma)
            })
            try consume(.keyword(.from))
            return .extract(from: try parseUse(in: basicBlock).0, at: keys)

        /// 'insert' <val> 'to' <val> 'at' <num|key|val> (',' <num|key|val>)*
        case .insert:
            let (srcVal, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.to))
            let (destVal, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.at))
            let keys: [ElementKey] = try parseMany({
                try parseElementKey(in: basicBlock).0
            }, separatedBy: {
                try consumeWrappablePunctuation(.comma)
            })
            return .insert(srcVal, to: destVal, at: keys)

        /// 'apply' <val> '(' <val>+ ')'
        case .apply:
            return try withPeekedToken("a function identifier") { tok in
                guard case let .identifier(kind, name) = tok.kind else { return nil }
                consumeToken()
                let fn: Value
                switch kind {
                case .global:
                    guard let val = symbolTable.globals[name] else { return nil }
                    fn = val
                case .temporary:
                    guard let val = symbolTable.locals[name] else { return nil }
                    fn = val
                default:
                    return nil
                }
                try consume(.punctuation(.leftParenthesis))
                let args = try parseUseList(in: basicBlock,
                                            unless: { $0.kind == .punctuation(.rightParenthesis) })
                try consume(.punctuation(.rightParenthesis))
                let (allegedTy, _) = try parseTypeSignature()
                /* TODO: Uncomment this when scanned prototypes have full types
                guard typeSig == fn.type else {
                    throw ParseError.typeMismatch(expected: fn.type, typeSigRange)
                }
                */
                var use = fn.makeUse()
                use.type = allegedTy
                return .apply(use, args)
            }

        /// 'allocateStack' <type> 'count' <num>
        case .allocateStack:
            let (type, _) = try parseType()
            try consume(.keyword(.count))
            let (count, _) = try parseInteger()
            return .allocateStack(type, count)
            
        /// 'allocateHeap' <type> 'count' <val>
        case .allocateHeap:
            let (type, _) = try parseType()
            try consume(.keyword(.count))
            let (count, _) = try parseUse(in: basicBlock)
            return .allocateHeap(type, count: count)
            
        /// 'allocateBox' <type>
        case .allocateBox:
            return try .allocateBox(parseType().0)

        /// 'projectBox' <val>
        case .projectBox:
            return try .projectBox(parseUse(in: basicBlock).0)

        /// 'retain' <val>
        case .retain:
            return try .retain(parseUse(in: basicBlock).0)

        /// 'release' <val>
        case .release:
            return try .release(parseUse(in: basicBlock).0)

        /// 'deallocate' <val>
        case .deallocate:
            return try .deallocate(parseUse(in: basicBlock).0)

        /// 'load' <val>
        case .load:
            return try .load(parseUse(in: basicBlock).0)

        /// 'store' <val> 'to' <val>
        case .store:
            let (src, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.to))
            let (dest, _) = try parseUse(in: basicBlock)
            return .store(src, to: dest)
            
        /// 'elementPointer' <val> 'at' <num|key|val> (<num|key|val> ',')*
        case .elementPointer:
            let (base, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.at))
            let keys: [ElementKey] = try parseMany({
                try parseElementKey(in: basicBlock).0
            }, separatedBy: {
                try consumeWrappablePunctuation(.comma)
            })
            return .elementPointer(base, keys)

        /// 'copy' 'from' <val> 'to' <val> 'count' <val>
        case .copy:
            try consume(.keyword(.from))
            let (src, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.to))
            let (dest, _) = try parseUse(in: basicBlock)
            try consume(.keyword(.count))
            let (count, _) = try parseUse(in: basicBlock)
            return .copy(from: src, to: dest, count: count)
            
        case .trap:
            return .trap
            
        /// <binary_op> <val>, <val>
        case let .binaryOp(op):
            let (lhs, _) = try parseUse(in: basicBlock)
            try consumeWrappablePunctuation(.comma)
            let (rhs, _) = try parseUse(in: basicBlock)
            return .zipWith(op, lhs, rhs)

        /// <unary_op> <val>
        case let .unaryOp(op):
            return try .map(op, parseUse(in: basicBlock).0)
        }
    }

    func parseInstruction(in basicBlock: BasicBlock) throws -> Instruction? {
        guard let tok = currentToken else { return nil }
        func parseKind(isNamed: Bool) throws -> InstructionKind {
            let kind = try parseInstructionKind(in: basicBlock)
            let type = kind.type
            /// If instruction kind gives invalid result, operands gotta be wrong
            guard type != .invalid else {
                throw ParseError.invalidOperands(tok, kind.opcode)
            }
            /// Cannot have void type
            if isNamed, type == .void {
                throw ParseError.cannotNameVoidValue(tok)
            }
            return kind
        }
        switch tok.kind {
        case let .identifier(.temporary, name):
            consumeToken()
            try consumeWrappablePunctuation(.equal)
            let kind = try parseKind(isNamed: true)
            guard !symbolTable.locals.keys.contains(name) else {
                throw ParseError.redefinedIdentifier(tok)
            }
            let inst = Instruction(name: name, kind: kind, parent: basicBlock)
            symbolTable.locals[name] = inst
            return inst
        case let .anonymousIdentifier(bbIndex, instIndex):
            /// Check BB index and instruction index
            /// - BB index must equal the current BB index
            /// - Instruction index must equal the next instruction index, 
            ///   i.e. the current instruction count
            guard bbIndex == basicBlock.parent.count, // BB hasn't been added to function
                instIndex == basicBlock.endIndex // Inst hasn't been added to BB
                else { throw ParseError.invalidAnonymousIdentifierIndex(tok) }
            consumeToken()
            try consumeWrappablePunctuation(.equal)
            let kind = try parseKind(isNamed: true)
            return Instruction(kind: kind, parent: basicBlock)
        case .opcode(_):
            return Instruction(kind: try parseKind(isNamed: false), parent: basicBlock)
        default:
            return nil
        }
    }

    func parseArgumentList() throws -> [(String, Type)] {
        return try parseMany({
            let (name, _) = try parseIdentifier(ofKind: .temporary, isDefinition: true)
            let (type, _) = try parseTypeSignature()
            return (name, type)
        }, unless: { tok in
            tok.kind == .punctuation(.rightParenthesis)
        }, separatedBy: {
            try self.consumeWrappablePunctuation(.comma)
        })
    }

    func parseBasicBlock(in function: Function) throws -> BasicBlock? {
        /// Parse basic block header
        guard case .identifier(.basicBlock, let name)? = currentToken?.kind else {
            return nil
        }
        consumeToken()
        try consumeWrappablePunctuation(.leftParenthesis)
        let args = try parseArgumentList()
        try consumeWrappablePunctuation(.rightParenthesis)
        try consume(.punctuation(.colon))
        try consumeOneOrMore(.newLine)
        /// Retrieve previously added BB during scanning
        guard let bb = symbolTable.basicBlocks[name] else {
            preconditionFailure("Should've been added during the symbol scanning stage")
        }
        for (name, type) in args {
            let arg = Argument(name: name, type: type, parent: bb)
            bb.arguments.append(arg)
            /// Insert args into symbol table
            symbolTable.locals[arg.name] = arg
        }
        /// Parse instructions
        while let inst = try parseInstruction(in: bb) {
            bb.append(inst)
            try consumeOneOrMore(.newLine)
        }
        return bb
    }

    func parseIndexList() throws -> [Int] {
        return try parseMany({
            try parseInteger().0
        }, separatedBy: {
            try self.consumeWrappablePunctuation(.comma)
        })
    }

    func parseFunctionDeclarationKind() throws -> Function.DeclarationKind {
        return try withPeekedToken("a declaration kind ('extern' or 'gradient')", { tok in
            switch tok.kind {
            case .keyword(.gradient):
                consumeToken()
                let (fnName, tok) = try parseIdentifier(ofKind: .global)
                guard let fn = symbolTable.globals[fnName] as? Function else {
                    throw ParseError.undefinedIdentifier(tok)
                }
                /// from
                var from: Int?
                if case .keyword(.from)? = currentToken?.kind {
                    consumeToken()
                    from = try parseInteger().0
                }
                /// wrt
                try consume(.keyword(.wrt))
                let wrt = try parseMany({
                    try parseInteger().0
                }, separatedBy: {
                    try consume(.punctuation(.comma))
                })
                /// keeping
                var keeping: [Int] = []
                if case .keyword(.keeping)? = currentToken?.kind {
                    consumeToken()
                    keeping = try parseMany({
                        try parseInteger().0
                    }, separatedBy: {
                        try consume(.punctuation(.comma))
                    })
                }
                /// seedable
                var isSeedable = false
                if case .keyword(.seedable)? = currentToken?.kind {
                    consumeToken()
                    isSeedable = true
                }
                return .gradient(of: fn, from: from, wrt: wrt, keeping: keeping, seedable: isSeedable)
                
            case .keyword(.extern):
                consumeToken()
                return .external
            default:
                return nil
            }
        })
    }
    
    func parseFunction(in module: Module) throws -> Function {
        /// Parse attributes
        var attributes: Set<Function.Attribute> = []
        while case let .attribute(attr)? = currentToken?.kind {
            attributes.insert(attr)
            consumeToken()
            consumeAnyNewLines()
        }
        /// Parse declaration kind
        var declKind: Function.DeclarationKind?
        if case .punctuation(.leftSquareBracket)? = currentToken?.kind {
            consumeToken()
            declKind = try parseFunctionDeclarationKind()
            try consume(.punctuation(.rightSquareBracket))
            consumeAnyNewLines()
        }
        /// Parse main function declaration/definition
        let funcTok = try consume(.keyword(.func))
        let (name, _) = try parseIdentifier(ofKind: .global)
        let (type, typeSigRange) = try parseTypeSignature()
        /// Ensure it's a function type
        guard case let .function(args, ret) = type.canonical else {
            throw ParseError.notFunctionType(typeSigRange)
        }
        /// Retrieve previous added function during scanning
        guard let function = symbolTable.globals[name] as? Function else {
            preconditionFailure("Should've been added during the symbol scanning stage")
        }
        /// Complete function's properties
        function.declarationKind = declKind
        function.argumentTypes = args
        function.returnType = ret
        function.attributes = attributes
        /// Scan basic block symbols and create prototypes in the symbol table
        withPreservedState {
            while restTokens.count >= 2 {
                let start = restTokens.startIndex
                let (tok0, tok1) = (restTokens[start], restTokens[start+1])
                /// End of function, break
                if tok0.kind == .punctuation(.rightCurlyBracket) { break }
                if case (.newLine, .identifier(.basicBlock, let name)) = (tok0.kind, tok1.kind) {
                    let proto = BasicBlock(name: name, arguments: [], parent: function)
                    symbolTable.basicBlocks[name] = proto
                    restTokens.removeFirst(2)
                    continue
                }
                consumeToken()
            }
        }
        /// Parse definition in `{...}` when it's not a declaration
        if function.isDefinition {
            try consumeWrappablePunctuation(.leftCurlyBracket)
            while let bb = try parseBasicBlock(in: function) {
                function.append(bb)
            }
            try consume(.punctuation(.rightCurlyBracket))
        }
        /// Otherwise if `{` follows the declaration, emit proper diagnostics
        else if let tok = currentToken, tok.kind == .punctuation(.leftCurlyBracket) {
            throw ParseError.declarationCannotHaveBody(
                declaration: funcTok.startLocation..<typeSigRange.upperBound,
                body: tok
            )
        }
        /// Clear function-local mappings from the symbol table
        symbolTable.basicBlocks.removeAll()
        symbolTable.locals.removeAll()
        return function
    }

    func parseTypeAlias(in module: Module) throws -> TypeAlias {
        try consume(.keyword(.type))
        let (name, _) = try parseIdentifier(ofKind: .type, isDefinition: true)
        try consumeWrappablePunctuation(.equal)
        let type: Type? = try withPeekedToken("a type") { tok in
            switch tok.kind {
            case .keyword(.opaque):
                consumeToken()
                return nil as Type?
            default:
                return try parseType().0
            }
        }
        let alias = TypeAlias(name: name, type: type)
        symbolTable.nominalTypes[name] = .alias(alias)
        return alias
    }

    func parseStruct(in module: Module) throws -> StructType {
        try consume(.keyword(.struct))
        let (name, _) = try parseIdentifier(ofKind: .type, isDefinition: true)
        try consumeWrappablePunctuation(.leftCurlyBracket)
        let fields: [StructType.Field] = try parseMany({
            /// If '}' follows the last comma, accept (backtrack)
            if currentToken?.kind == .punctuation(.rightCurlyBracket) {
                return nil
            }
            let (name, _) = try parseIdentifier(ofKind: .key)
            let (type, _) = try parseTypeSignature()
            return (name: name, type: type)
        }, separatedBy: {
            try consumeWrappablePunctuation(.comma)
        })
        consumeAnyNewLines()
        try consume(.punctuation(.rightCurlyBracket))
        let structTy = StructType(name: name, fields: fields)
        symbolTable.nominalTypes[name] = .struct(structTy)
        return structTy
    }
}

public extension Parser {
    /// Parser entry
    func parseModule() throws -> Module {
        consumeAnyNewLines()
        try consume(.keyword(.module))
        let name = try consumeStringLiteral()
        /// Stage
        try consumeOneOrMore(.newLine)
        try consume(.keyword(.stage))
        let stage: Module.Stage = try withPeekedToken("'raw' or 'canonical'", { tok in
            switch tok.kind {
            case .keyword(.raw):
                consumeToken()
                return .raw
            case .keyword(.canonical):
                consumeToken()
                return .canonical
            default: return nil
            }
        })
        let module = Module(name: name, stage: stage)

        /// Scan function symbols and create prototypes in the symbol table
        withPreservedState {
            while restTokens.count >= 3 {
                let start = restTokens.startIndex
                let (tok0, tok1, tok2) = (restTokens[start], restTokens[start+1], restTokens[start+2])
                if case (.newLine, .keyword(.func), .identifier(.global, let name)) = (tok0.kind, tok1.kind, tok2.kind) {
                    let proto = Function(name: name, argumentTypes: [], returnType: .invalid, parent: module)
                    symbolTable.globals[name] = proto
                    restTokens.removeFirst(3)
                    continue
                }
                consumeToken()
            }
        }

        try consumeOneOrMore(.newLine)
        /// Parse top-level declarations/definitions
        while let tok = currentToken {
            switch tok.kind {
            case .keyword(.type):
                let type = try parseTypeAlias(in: module)
                module.typeAliases.append(type)

            case .keyword(.struct):
                let structure = try parseStruct(in: module)
                module.structs.append(structure)

            case .keyword(.func), .attribute(_), .punctuation(.leftSquareBracket):
                let fn = try parseFunction(in: module)
                module.append(fn)

            default:
                throw ParseError.unexpectedToken(
                    expected: "a type alias, a struct or a function", tok
                )
            }
            if isEOF { break }
            try consumeOneOrMore(.newLine)
        }

        /// ... end of input
        return module
    }
}