//
//  AD.swift
//  LLNM
//
//  Created by Richard Wei on 11/13/16.
//
//

import CUDARuntime
import CCuDNN
import CuBLAS

extension Assignment {

    func propogateForward() {
        switch rValue {
        case let .add(lhs, rhs):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { ptrC -> () in
                lhs.data.withUnsafeDeviceAddress { ptrA in
                    rhs.data.withUnsafeDeviceAddress { ptrB in
                        !!cudnnOpTensor(
                            graph.dnn.handle,
                            graph.tensorOperators.addOp,
                            &one, lhs.data.descriptor.handle, ptrA,
                            &one, rhs.data.descriptor.handle, ptrB,
                            &zero, self.data.descriptor.handle, ptrC
                        )
                    }
                }
            }
        case let .mul(lhs, rhs):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { ptrC -> () in
                lhs.data.withUnsafeDeviceAddress { ptrA in
                    rhs.data.withUnsafeDeviceAddress { ptrB in
                        !!cudnnOpTensor(
                            graph.dnn.handle,
                            graph.tensorOperators.mulOp,
                            &one, lhs.data.descriptor.handle, ptrA,
                            &one, rhs.data.descriptor.handle, ptrB,
                            &zero, self.data.descriptor.handle, ptrC
                        )
                    }
                }
            }

        case let .min(lhs, rhs):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { ptrC -> () in
                lhs.data.withUnsafeDeviceAddress { ptrA in
                    rhs.data.withUnsafeDeviceAddress { ptrB in
                        !!cudnnOpTensor(
                            graph.dnn.handle,
                            graph.tensorOperators.minOp,
                            &one, lhs.data.descriptor.handle, ptrA,
                            &one, rhs.data.descriptor.handle, ptrB,
                            &zero, self.data.descriptor.handle, ptrC
                        )
                    }
                }
            }

        case let .max(lhs, rhs):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { ptrC -> () in
                lhs.data.withUnsafeDeviceAddress { ptrA in
                    rhs.data.withUnsafeDeviceAddress { ptrB in
                        !!cudnnOpTensor(
                            graph.dnn.handle,
                            graph.tensorOperators.maxOp,
                            &one, lhs.data.descriptor.handle, ptrA,
                            &one, rhs.data.descriptor.handle, ptrB,
                            &zero, self.data.descriptor.handle, ptrC
                        )
                    }
                }
            }
            
        case let .tanh(x):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { dest -> () in
                x.data.withUnsafeDeviceAddress { src in
                    !!cudnnActivationForward_v4(
                        graph.dnn.handle,
                        graph.tensorOperators.tanhActivation,
                        &one, x.data.descriptor.handle, src,
                        &zero, data.descriptor.handle, dest
                    )
                }
            }

        case let .relu(x):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { dest -> () in
                x.data.withUnsafeDeviceAddress { src in
                    cudnnActivationForward_v4(
                        graph.dnn.handle,
                        graph.tensorOperators.reluActivation,
                        &one, x.data.descriptor.handle, src,
                        &zero, data.descriptor.handle, dest
                    )
                }
            }

        case let .sigmoid(x):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { dest -> () in
                x.data.withUnsafeDeviceAddress { src in
                    cudnnActivationForward_v4(
                        graph.dnn.handle,
                        graph.tensorOperators.sigmoidActivation,
                        &one, x.data.descriptor.handle, src,
                        &zero, data.descriptor.handle, dest
                    )
                }
            }
            
        case let .softmax(x):
            var one: DataType = 1
            var zero = DataType.zero
            self.data.withUnsafeMutableDeviceAddress { dest -> () in
                x.data.withUnsafeDeviceAddress { src in
                    !!cudnnSoftmaxForward(
                        graph.dnn.handle,
                        CUDNN_SOFTMAX_LOG,
                        CUDNN_SOFTMAX_MODE_CHANNEL,
                        &one, x.data.descriptor.handle, src,
                        &zero, data.descriptor.handle, dest)
                }
            }

        }

    }
}
