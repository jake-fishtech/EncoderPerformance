//
//  HEVCEncoder.swift
//  Encoder-Performance
//
//  Created by Jake Fishman on 1/19/25.
//

import AVFoundation
import VideoToolbox


class SimpleHEVCCodec {
    private var encoderSession: VTCompressionSession?
    private var width: Int32
    private var height: Int32
    private var bitrate: Int
    private var usingSoftwareDecoder: Bool = false
    
    init?(width: Int32, height: Int32, bitrate: Int) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        guard setupEncoder() else {
            return nil
        }
    }
    
    private func setupEncoder() -> Bool {
        let encoderSpecification: [String: Any] = [:]
        let imageBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        
        var status = VTCompressionSessionCreate(allocator: nil,
                                              width: width,
                                              height: height,
                                              codecType: kCMVideoCodecType_HEVC,
                                              encoderSpecification: encoderSpecification as CFDictionary,
                                              imageBufferAttributes: imageBufferAttributes as CFDictionary,
                                              compressedDataAllocator: nil,
                                              outputCallback: nil,
                                              refcon: nil,
                                              compressionSessionOut: &encoderSession)
        
        guard status == noErr, let session = encoderSession else {
            print("Failed to create encoder session: \(status)")
            return false
        }
        
        // Set real-time encoding properties
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        
        // Set the average bit rate
        status = VTSessionSetProperty(session,
                                    key: kVTCompressionPropertyKey_AverageBitRate,
                                    value: NSNumber(value: bitrate))
        
        // Use default key frame interval (typically 1-2 seconds)
        status = VTSessionSetProperty(session,
                                    key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                    value: NSNumber(value: 1)) // 1 second
        
        // Allow frame reordering for better compression
        status = VTSessionSetProperty(session,
                                    key: kVTCompressionPropertyKey_AllowFrameReordering,
                                    value: kCFBooleanFalse)
        
        // Enable hardware acceleration
        status = VTSessionSetProperty(session,
                                    key: kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                                    value: kCFBooleanTrue)
        
        // Prepare the encoder
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        
        return status == noErr
    }
    
    func calculatePixelBufferHash(from pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let size = height * bytesPerRow
        
        // FNV-1a hash
        let fnvPrime: UInt64 = 1099511628211
        var hash: UInt64 = 14695981039346656037
        
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        //stride(from: 0, to: totalSize, by: 16)
        for i in  stride(from: 0, to: size, by: 16) {
            hash = hash ^ UInt64(bytes[i])
            hash = hash &* fnvPrime
        }
        
        return hash
    }
    
    func isKeyFrame(sampleBuffer: CMSampleBuffer) -> Bool {
        // Get attachments array from sample buffer
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              let attachmentDict = (attachmentsArray as NSArray).object(at: 0) as? [CFString: Any] else {
            return false // Assume not a keyframe if no attachments
        }
        
        // Check if the key kCMSampleAttachmentKey_NotSync exists
        // If it does not exist, it's a keyframe
        return attachmentDict[kCMSampleAttachmentKey_NotSync] == nil
    }
    
    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime, completion: @escaping (CMSampleBuffer?, Bool) -> Void) {
        
        guard let session = encoderSession else {
            print("Encoder session not initialized")
            completion(nil, false)
            return
        }
        
        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: presentationTimeStamp,
                                                     duration: duration,
                                                     frameProperties: nil,
                                                     infoFlagsOut: nil) { status, infoFlags, sampleBuffer in
            
            if status == noErr, let sampleBuffer = sampleBuffer {
                let isKeyFrame = self.isKeyFrame(sampleBuffer: sampleBuffer)
                completion(sampleBuffer, isKeyFrame)
            } else {
                print("Failed to encode frame: \(status)")
                if sampleBuffer == nil {
                    print("Sample buffer is nil")
                }
                completion(nil, false)
            }
        }
    }
    
    
    // Fast hash calculation for compressed data
    private func calculateCompressedDataHash(from sampleBuffer: CMSampleBuffer) -> UInt64 {
        // Method 1: Using block buffer data pointer directly (fastest)
        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            var temporaryDataPointer: UnsafeMutablePointer<Int8>? = nil
            
            CMBlockBufferGetDataPointer(dataBuffer,
                                        atOffset: 0,
                                        lengthAtOffsetOut: &length,
                                        totalLengthOut: nil,
                                        dataPointerOut: &dataPointer)
            
            if let pointer = dataPointer {
                // FNV-1a hash (very fast and good distribution)
                let fnvPrime: UInt64 = 1099511628211
                var hash: UInt64 = 14695981039346656037
                
                // Process 8 bytes at a time for speed
                let wordPointer = pointer.withMemoryRebound(to: UInt64.self, capacity: length / 8) { $0 }
                let wordCount = length / 8
                
                for i in 0..<wordCount {
                    hash = hash ^ wordPointer[i]
                    hash = hash &* fnvPrime
                }
                
                // Process remaining bytes
                let remainingStart = wordCount * 8
                for i in remainingStart..<length {
                    hash = hash ^ UInt64(UInt8(bitPattern: pointer[i]))
                    hash = hash &* fnvPrime
                }
                
                return hash
            }
        }
        
        return 0
    }
    
    // Alternative method using sample size (less accurate but very fast)
    private func calculateQuickHash(from sampleBuffer: CMSampleBuffer) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        
        // Get sample size
        let sampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        hash ^= UInt64(sampleSize)
        
        // Include timing info in hash
        if let timing = getSampleTiming(from: sampleBuffer) {
            hash ^= UInt64(timing.duration.value)
            hash ^= UInt64(timing.presentationTimeStamp.value)
        }
        
        // Include format description
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
            hash ^= UInt64(dimensions.width)
            hash ^= UInt64(dimensions.height)
        }
        
        return hash
    }
    
    private func getSampleTiming(from sampleBuffer: CMSampleBuffer) -> CMSampleTimingInfo? {
        var timingInfo = CMSampleTimingInfo()
        let status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)
        return status == noErr ? timingInfo : nil
    }
    
    
    deinit {
        if let session = encoderSession {
            VTCompressionSessionInvalidate(session)
        }
    }
    
    func encode(pixelBuffer: CVPixelBuffer,presentationTimeStamp: CMTime, duration: CMTime) async -> (CMSampleBuffer?, Bool) {
        await withCheckedContinuation { continuation in
            encode(pixelBuffer: pixelBuffer, presentationTimeStamp:presentationTimeStamp, duration:duration) { sampleBuffer, isKeyFrame in
                continuation.resume(returning: (sampleBuffer, isKeyFrame))
            }
        }
    }
}
