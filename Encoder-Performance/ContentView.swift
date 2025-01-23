//
//  ContentView.swift
//  Encoder-Performance
//
//  Created by Jake Fishman on 1/19/25.
//

import SwiftUI
import AVFoundation
import PhotosUI
import Combine

struct CameraView: View {
    @ObservedObject var cameraManager: BrianCameraManager
    @State private var deviceOrientation: UIDeviceOrientation = .portrait
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let previewLayer = cameraManager.previewLayer {
                    LiveCameraView(previewLayer: previewLayer)
                }
            }
        }
    }
}


struct LiveCameraView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.handleDeviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        
        // Manually trigger orientation update to ensure correct initial state
        context.coordinator.handleDeviceOrientationDidChange()
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Ensure the previewLayer frame matches the bounds of the view
        previewLayer.frame = uiView.bounds
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: LiveCameraView
        
        init(_ parent: LiveCameraView) {
            self.parent = parent
        }
        
        @objc func handleDeviceOrientationDidChange() {
            DispatchQueue.main.async {
                guard let connection = self.parent.previewLayer.connection else {
                    return
                }
                
                // Update the previewLayer frame
                if let superview = self.parent.previewLayer.superlayer?.delegate as? UIView {
                    self.parent.previewLayer.frame = superview.bounds
                }
                
                // Update the video rotation angle to match the device orientation
                switch UIDevice.current.orientation {
                case .portrait:
                    connection.videoRotationAngle = 90
                case .portraitUpsideDown:
                    connection.videoRotationAngle = 90
                case .landscapeLeft:
                    connection.videoRotationAngle = 0
                case .landscapeRight:
                    connection.videoRotationAngle = 180
                default:
                    connection.videoRotationAngle = 90
                }
                
                print("Orientation changed, updated rotation angle to: \(connection.videoRotationAngle)")
            }
        }
    }
}

struct ContentView: View {

    let cameraManager: BrianCameraManager
    
    @State private var isPaused = false
    @State private var isDisplayVideo = true
    @Binding var fpsCurrent: Double
    
    var body: some View {
        ZStack {
            CameraView(cameraManager: cameraManager)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                HStack {
                    Text("PLVision")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding()
                        .cornerRadius(10)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.1f FPS", cameraManager.fpsCurrent))
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%.1f PPS", cameraManager.ppsCurrent))
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%d frames", cameraManager.totalCaptures))
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%.1f MB", cameraManager.totalMemory))
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .padding([.top, .trailing], 16)
                }
                
                Spacer()
                Spacer()
                Spacer()
                HStack {
                    Button(action: {
                        isPaused.toggle()
                        if isPaused {
                            cameraManager.stopRunning()
                        } else {
                            cameraManager.startRunning()
                        }
                    }) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}
