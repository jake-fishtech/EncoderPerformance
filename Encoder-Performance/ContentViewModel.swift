//
//  ContentViewModel.swift
//  Encoder-Performance
//
//  Created by Jake Fishman on 1/19/25.
//

import AVFoundation
import SwiftUI
import CoreML
import CoreImage
import Vision
import CoreVideo
import Accelerate
import Photos
import SwiftData
import Combine

let SHOW_PROCESSED_VIDEO = true
let RING_BUFFER_SIZE = 420

class BrianCameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var currentOrientation: UIDeviceOrientation = .portrait
    
    @Published var isRunning = false   // start stop video input and processing
    
    @Published var fpsCurrent: Double = 0  // FPS number displayed
    @Published var ppsCurrent: Double = 0  // Processes Per Sec number displayed
    @Published var totalCaptures: Int64  = 0
    @Published var totalMemory: Double = 0.0
    
    @Published var cameraPermissionGranted = false
    @Published var shouldShowPermissionAlert = false
    
    private var isCapturing = true
    
    let captureSession = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    
    // for FPS display
    var fpsFrameCount = 0
    private var ppsFrameCount = 0
    var fpsLastTimestamp = CACurrentMediaTime()
    var nonPublishedCaptures:Int64 = 0
    var nonPublishedCapturesTotal:Int64 = 0
    var keyFrameFrequency:Int = 4
    
    private  let contextDisplay : CIContext
    
    public var useImageStabilization = true
 
    private var videoFrameCount = 0
    
    var fpsUpdateTask: Task<Void, Never>?
    
    private var _isProcessing = false
    private let lockProcessingBool = NSLock()
    
    var processFileSemaphore : DispatchSemaphore
    
    var ringBuffer : RingBuffer
        
    var compressedSemaphore : DispatchSemaphore
   
    var codec : SimpleHEVCCodec
    private var captureDevice: AVCaptureDevice?
    
    // thread safe isProcessing bool
    var isProcessing: Bool {
        get {
            lockProcessingBool.lock()
            defer { lockProcessingBool.unlock() }
            return _isProcessing
        }
        set {
            lockProcessingBool.lock()
            _isProcessing = newValue
            lockProcessingBool.unlock()
        }
    }
    
    override init() {
        
        self.ringBuffer = RingBuffer(capacity: RING_BUFFER_SIZE)
        self.codec = SimpleHEVCCodec(width: 3840, height: 2160, bitrate: 100_000_000, keyFrameEveryN: keyFrameFrequency)!
        
        self.contextDisplay = CIContext(options: nil)
        self.processFileSemaphore = DispatchSemaphore(value: 0)
        self.compressedSemaphore = DispatchSemaphore(value: 0)
        
        super.init()
        
        setupCaptureDevice()
        setupCaptureSession(enableStabilization: self.useImageStabilization)
        
        Task { @MainActor in setupFPSUpdate() }
        
        startProcessing()
    }
    
    
    func cleanup() {
        print("cleaning up brian camera manager")
        stopRunning()
        stopProcessing()
        fpsUpdateTask?.cancel()
    }
    
    func updateOrientation(to newOrientation: UIDeviceOrientation) {
        DispatchQueue.main.async {
            self.currentOrientation = newOrientation
            print("Updated orientation to: \(newOrientation.rawValue)")
        }
    }
    
    // this is a timer loop that calls periodic update every 1 second to update  on-screen information
    @MainActor
    func setupFPSUpdate() {
        fpsUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.periodicUpdate()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    // Task was cancelled
                    break
                }
            }
        }
    }
    
    // on-screen informaton
    @MainActor
    private func periodicUpdate() {
        let currentTime = CACurrentMediaTime()
        
        let elapsedTime = currentTime - fpsLastTimestamp
        fpsCurrent = Double(fpsFrameCount) / elapsedTime
        fpsFrameCount = 0
        
        ppsCurrent = Double(ppsFrameCount) / elapsedTime
        ppsFrameCount = 0
        fpsLastTimestamp = currentTime
        
        let memoryInBytes = reportMemoryUsage()
        totalMemory = Double(memoryInBytes) / 1_048_576.0 // Convert to MB
        
        print("FPS = \(fpsCurrent)")
        print("PPS = \(ppsCurrent)")
        
    }
    
    private func setupCaptureDevice() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("No suitable camera found")
            return
        }
        self.captureDevice = device
    }
    
    func setupCaptureSession(enableStabilization: Bool) {
        captureSession.sessionPreset = .hd4K3840x2160
        
        guard let device = captureDevice else {
            print("No suitable camera found")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            // Initialize preview layer here
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                previewLayer.videoGravity = .resizeAspectFill
                self.previewLayer = previewLayer
            }
            
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            
            let videoQueue = DispatchQueue(label: "app.pitchlab.videoQueue", qos: .userInitiated)
            
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            } else {
                print("Error: Could not add output to capture session")
                return
            }
            
            // Configure device settings (frame rate, exposure, etc.)
            try device.lockForConfiguration()
            
            // Find and set 4K 120FPS format
            if let format = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let is4K = dimensions.width == 3840 && dimensions.height == 2160
                let frameRates = format.videoSupportedFrameRateRanges
                return is4K && frameRates.contains(where: { $0.maxFrameRate >= 120 })
            }) {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 120)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 120)
                device.activeMaxExposureDuration = CMTime(seconds: 1.0 / 960, preferredTimescale: 1000000)
            }
            
            device.unlockForConfiguration()
            
            // Set video stabilization
            if let videoConnection = videoOutput.connection(with: .video) {
                if videoConnection.isVideoStabilizationSupported {
                    videoConnection.preferredVideoStabilizationMode = enableStabilization ? .standard : .off
                } else {
                    print("Video stabilization is not supported on this device.")
                }
            }
            
        } catch {
            print("Failed to set up camera: \(error.localizedDescription)")
        }
    }
    
    // this is the main callback function to handle video frames captured
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        let deviceOrientation = self.currentOrientation
        var cameraOrientation : CGImagePropertyOrientation
        
        switch deviceOrientation {
        case .portrait:
            cameraOrientation = .up
        case .portraitUpsideDown:
            cameraOrientation = .down
        case .landscapeLeft:
            cameraOrientation = .left
        case .landscapeRight:
            cameraOrientation = .right
        default:
            cameraOrientation = .up
        }
        
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        // Handle invalid duration
        if duration == CMTime.invalid {
            // Set a default duration based on your frame rate
            let frameRate: Double = 120.0 // Replace with your actual frame rate
            duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }
        
        // extract pixelbuffer from sample
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            self.processFrame(imageBuffer: pixelBuffer, presentationTimeStamp: presentationTimeStamp, duration: duration, orientation: cameraOrientation)
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.totalCaptures =  self?.nonPublishedCapturesTotal ?? 0
            self?.fpsFrameCount += 1
        }
        
    }
    
    private func startProcessing() {
        nonPublishedCaptures = 0
        isProcessing = true
        let processingQueue = DispatchQueue(label: "app.pitchlab.videoProcessingQueue", qos: .userInitiated)
        
        processingQueue.async { [weak self] in
        }
    }
    
    private func stopProcessing() {
        isProcessing = false
    }
    
    func processFrame(imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime, duration: CMTime, orientation: CGImagePropertyOrientation, store:Bool = true)  {
        
        let t = presentationTimeStamp.seconds
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let minSize = min(height, width)
        let is4k = minSize > 1080
        
        codec.encode(pixelBuffer: imageBuffer,presentationTimeStamp: presentationTimeStamp, duration: duration) { [weak self] (encodedSampleBuffer, isKeyFrame) in
            guard let self = self else { return }
            guard let encodedSampleBuffer = encodedSampleBuffer else {
                print("Encoding failed")
                return
            }
            
            let frameData = FrameData(sampleBuffer: encodedSampleBuffer, timestamp: presentationTimeStamp, isKeyFrame: isKeyFrame)
            self.ringBuffer.append(frameData)
            
            
        }
        
        nonPublishedCaptures += 1
        nonPublishedCapturesTotal += 1
        
        Task { @MainActor in
            ppsFrameCount += 1
        }
    }
 
    func reportMemoryUsage() -> Int64 {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size) / 4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Int64(info.resident_size) // Memory in bytes
        } else {
            return -1 // Failed to fetch memory usage
        }
    }
}


extension BrianCameraManager {
    
    func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            await MainActor.run {
                self.cameraPermissionGranted = true
                self.startRunning()
            }
        case .notDetermined:
            // Request access
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                self.cameraPermissionGranted = granted
                if granted {
                    self.startRunning()
                } else {
                    self.shouldShowPermissionAlert = true
                }
            }
        case .denied, .restricted:
            await MainActor.run {
                self.cameraPermissionGranted = false
                self.shouldShowPermissionAlert = true
            }
        @unknown default:
            break
        }
    }
    
    // start video capture thread
    func startRunning() {
        guard cameraPermissionGranted else {
            Task {
                await checkCameraPermission()
            }
            return
        }
        
        guard !captureSession.isRunning else { return }
        
        ringBuffer.clear()
        
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let strongSelf = self else {
                        continuation.resume()
                        return
                    }
                    
                    strongSelf.captureSession.startRunning()
                    
                    DispatchQueue.main.async {
                        strongSelf.isRunning = true
                        continuation.resume()
                    }
                }
            }
        }
    }
    // stop video capture thread
    func stopRunning() {
        guard captureSession.isRunning else { return }
        
        Task {
            await withCheckedContinuation { continuation in
                Dispatch.DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let strongSelf = self else {
                        continuation.resume()
                        return
                    }
                    
                    strongSelf.captureSession.stopRunning()
                    
                    Dispatch.DispatchQueue.main.async {
                        strongSelf.isRunning = false
                        continuation.resume()
                    }
                }
            }
        }
    }
        
    func getOrientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation? {
        // Check for orientation metadata in the sample buffer
        if let orientationAttachment = CMGetAttachment(sampleBuffer, key: kCGImagePropertyOrientation, attachmentModeOut: nil) as? NSNumber {
            return CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value)
        }
        return nil
    }
}
