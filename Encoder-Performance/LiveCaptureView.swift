//
//  LiveCaptureView.swift
//  Encoder-Performance
//
//  Created by Jake Fishman on 1/19/25.
//

import SwiftUI
import Combine
import AVFoundation


struct LiveCaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    @StateObject private var cameraManager = BrianCameraManager()
    @State private var showingCameraPermissionAlert = false
    
    var body: some View {
        
        ContentView(
            cameraManager: cameraManager,
            fpsCurrent: $cameraManager.fpsCurrent
        )
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))

        .onAppear {
            Task {
                await cameraManager.checkCameraPermission()
            }
        }
        .onDisappear {
            cameraManager.cleanup()
        }
        
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .background, .inactive:
                cameraManager.stopRunning()
            case .active:
                cameraManager.startRunning()
            @unknown default:
                break
            }
        }
        .alert("Camera Access Required", isPresented: $cameraManager.shouldShowPermissionAlert) {
            Button("Open Settings", role: .none) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Please enable camera access in Settings to use this feature.")
        }
    }
}
