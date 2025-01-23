//
//  RingBuffer.swift
//  Encoder-Performance
//
//  Created by Jake Fishman on 1/19/25.
//

import AVFoundation

class FrameData {
    var sampleBuffer: CMSampleBuffer?
    var timestamp: CMTime
    var sequentialID: Int64
    var isKeyFrame: Bool

    init(sampleBuffer: CMSampleBuffer?, timestamp: CMTime, isKeyFrame: Bool) {
        self.sampleBuffer = sampleBuffer
        self.timestamp = timestamp
        self.isKeyFrame = isKeyFrame
        self.sequentialID = -1
    }
}

class RingBuffer {
    private var buffer: [FrameData?]
    private let capacity: Int
    private var head: Int = 0
    private var tail: Int = 0
    var count: Int = 0
    private var total: Int64 = 0
    private let semaphore = DispatchSemaphore(value: 1)
    private var isLocked: Bool = false

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [FrameData?](repeating: nil, count: capacity)
    }

    func getCount()-> Int {
        return count
    }
    
    func append(_ frameData: FrameData) {
     
        guard !self.isLocked else { return }
        
        frameData.sequentialID = self.total
        self.buffer[self.head] = frameData
        self.head = (self.head + 1) % self.capacity
      
        self.total += 1
        if self.count < self.capacity {
            self.count += 1
        } else {
            self.tail = (self.tail + 1) % self.capacity
        }
    }

    func lock() {
        semaphore.wait()
        isLocked = true
    }

    func unlock() {
        isLocked = false
        semaphore.signal()
    }
    
    func clear() {
            self.buffer = [FrameData?](repeating: nil, count: self.capacity)
            self.head = 0
            self.tail = 0
            self.count = 0
            self.total = 0
    }
}
