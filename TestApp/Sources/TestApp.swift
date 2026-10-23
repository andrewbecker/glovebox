import SwiftUI

// A small app for exercising glovebox end to end: a form to fill in, a tap that
// blocks the main thread, and a loading spinner. Built by TestApp/build.sh.

@main
struct TestApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    NavigationLink("Form") { FormScreen() }
                    NavigationLink("Busy main thread") { BusyScreen() }
                    NavigationLink("Spinner") { SpinnerScreen() }
                }
                .navigationTitle("glovebox Test")
            }
        }
    }
}

struct FormScreen: View {
    @State private var name = ""
    @State private var notifications = false
    @State private var count = 0
    @State private var submitted: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .accessibilityIdentifier("name")
            Toggle("Notifications", isOn: $notifications)
            Stepper("Count: \(count)", value: $count, in: 0...10)
            Button("Submit") {
                submitted = "Submitted \(name), notifications \(notifications ? "on" : "off"), count \(count)"
            }
            if let submitted {
                Text(submitted)
                    .accessibilityIdentifier("result")
            }
        }
        .navigationTitle("Form")
    }
}

/// Each tap blocks the main thread for 2 s before the label changes, so
/// nothing redraws within glovebox's default 1 s response window.
struct BusyScreen: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Taps: \(taps)")
                .accessibilityIdentifier("taps")
            Button("Block for 2 s") {
                Thread.sleep(forTimeInterval: 2)
                taps += 1
            }
        }
        .navigationTitle("Busy main thread")
    }
}

/// "Load" shows a spinner for 3 s, then "Loaded". The spinner below it runs
/// for as long as the screen is open.
struct SpinnerScreen: View {
    @State private var loading = false
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 24) {
            Button("Load") {
                loading = true
                loaded = false
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    loading = false
                    loaded = true
                }
            }
            if loading {
                ProgressView("Loading")
            }
            if loaded {
                Text("Loaded")
            }
            Spacer().frame(height: 40)
            ProgressView()
                .accessibilityLabel("Always spinning")
        }
        .navigationTitle("Spinner")
    }
}
