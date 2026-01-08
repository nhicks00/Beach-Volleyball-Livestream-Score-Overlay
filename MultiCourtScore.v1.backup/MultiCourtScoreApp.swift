//
//  MultiCourtScoreApp.swift
//  MultiCourtScore
//
//  Created by Nathan Hicks on 8/24/25.
//

import SwiftUI

@main
struct MultiCourtScoreApp: App {
    @StateObject private var vm = AppViewModel(defaultCount: 10)
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .onAppear {
                    // Start the local web server for overlays
                    vm.startServices()
                }
        }
    }
}
