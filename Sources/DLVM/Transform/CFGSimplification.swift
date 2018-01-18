//
//  CFGSimplification.swift
//  DLVM
//
//  Copyright 2016-2018 The DLVM Team.
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

/// Simplifies the control flow graph by performing dead code elimination and
/// basic block merging.
/// Specifically:
/// - Removes basic blocks with no predecessors.
/// - Merges a basic block into its predecessor if it has only one predecessor
///   and if the predecessor has only one successor.
/// - Merges a basic block into its predecessor if it contains only an
///   unconditional branch.
/// - Removes arguments from basic blocks with a single predecessor.

open class CFGSimplification : TransformPass {
    public typealias Body = Function
    
    public static func run(on body: Function) -> Bool {
        var changed = false
        var cfg = body.analysis(from: ControlFlowGraphAnalysis.self)

        /// Remove basic blocks that are not reachable from the entry.
        changed = removeUnreachableBlocks(in: body, controlFlow: &cfg)
            || changed

        /// Merge basic blocks into their predecessor if possible.
        changed = mergeBlocksIntoPredecessors(in: body, controlFlow: &cfg)
            || changed

        /// Remove arguments from basic blocks with a single predecessor.
        changed = removeBlockArgumentsIfUniquePredecessor(in: body, controlFlow: cfg)
            || changed

        return changed
    }

    public static func removeUnreachableBlocks(
        in function: Function,
        controlFlow cfg: inout DirectedGraph<BasicBlock>
    ) -> Bool {
        var changed = false
        /// Mark basic blocks that are reachable from entry.
        var visited: Set<BasicBlock> = []
        func markVisited(_ bb: BasicBlock) {
            if (visited.contains(bb)) { return }
            visited.insert(bb)
            bb.successors.forEach(markVisited)
        }
        markVisited(function[0])
        /// Remove unreachable basic blocks, updating CFG.
        for bb in function {
            if !visited.contains(bb) {
                function.remove(bb)
                cfg.removeNode(bb)
                changed = true
            }
        }
        return changed
    }

    public static func mergeBlocksIntoPredecessors(
        in function: Function,
        controlFlow cfg: inout DirectedGraph<BasicBlock>
    ) -> Bool {
        var changed = false
        for bb in function {
            /// Basic block can be merged if:
            /// - it has a unique predecessor and the predecessor has only one
            ///   successor
            /// - it contains only an unconditional branch
            let preds = cfg.predecessors(of: bb)
            let predsToMerge: OrderedSet<BasicBlock>
            if preds.count == 1 && preds[0].successorCount == 1 {
                predsToMerge = [preds[0]]
            } else if bb.count == 1, case .branch = bb.premise.terminator.kind {
                predsToMerge = preds
            } else {
                continue
            }
            for pred in predsToMerge {
                /// Remove terminator from predecessor.
                pred.premise.terminator.removeFromParent()
                /// Copy instructions into predecessor, replacing argument uses
                /// with their incoming values.
                let incomingValues = bb.arguments.map { $0.incomingValue(from: pred) }
                for inst in bb {
                    let newInst = Instruction(name: inst.name,
                                              kind: inst.kind, parent: pred)
                    for (old, new) in zip(bb.arguments, incomingValues) {
                        newInst.substitute(new, for: %old)
                    }
                    pred.append(newInst)
                }
                /// Update CFG.
                cfg.removeEdge(from: pred, to: bb)
                for succ in bb.successors {
                    cfg.removeEdge(from: bb, to: succ)
                    cfg.insertEdge(from: pred, to: succ)
                }
            }
            /// Remove basic block from function.
            bb.removeFromParent()
            changed = true
        }
        return changed
    }

    public static func removeBlockArgumentsIfUniquePredecessor(
        in function: Function,
        controlFlow cfg: DirectedGraph<BasicBlock>
    ) -> Bool {
        var changed = false
        for bb in function {
            /// Consider only the basic blocks that have a unique predecessor.
            let preds = cfg.predecessors(of: bb)
            guard preds.count == 1 else { continue }
            let pred = preds[0]
            /// Replace argument uses with their incoming values.
            let incomingValues = bb.arguments.map { $0.incomingValue(from: pred) }
            for inst in bb {
                for (old, new) in zip(bb.arguments, incomingValues) {
                    inst.substitute(new, for: %old)
                }
            }
            /// Remove all arguments.
            bb.arguments.removeAll(keepingCapacity: false)
            changed = true
        }
        return changed
    }
}