//
//  LiteralBroadcastingPromotion.swift
//  GPIR
//
//  Copyright 2018 The GPIR Team.
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

// TODO: Revisit when other literal types are implemented.

open class LiteralBroadcastingPromotion : TransformPass {
    public typealias Body = BasicBlock

    open class func run(on body: BasicBlock) -> Bool {
        var changed = false
        for inst in body {
            /// Instruction must be broadcastable
            switch inst.kind {
            case .booleanBinary: break
            default: continue
            }
            for operand in inst.operands {
                /// Operand must have scalar type
                guard case .bool = operand.type else {
                    continue
                }
                /// Operand must be a literal or literal instruction
                switch operand {
                case let .literal(_, .bool(lit)):
                    let newOperand: Use = .literal(.bool, .bool(lit))
                    inst.substitute(newOperand, for: operand)
                    changed = true
                case .definition(.instruction(let i)):
                    guard case let .literal(lit, ty) = i.kind,
                        case .bool = ty else {
                        break
                    }
                    changed = true
                    inst.substitute(.literal(.bool, lit), for: operand)
                default:
                    break
                }
            }
        }
        return changed
    }
}
