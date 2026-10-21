//
// ShowcaseSpikesView.swift
// EmoDrink Glasses
//
// Developer-only page for the four showcase hardware spikes. Buttons here,
// logic in ShowcaseSpikesViewModel (Services/ShowcaseSpikes.swift).
//

import SwiftUI

struct ShowcaseSpikesView: View {
    @State private var viewModel: ShowcaseSpikesViewModel

    init(link: GlassesLink) {
        _viewModel = State(initialValue: ShowcaseSpikesViewModel(link: link))
    }

    var body: some View {
        HermesScrollPage {
            HermesSection(header: "Video",
                          footer: "Plays a generated 5 s clip on the lens. File sends a file:// URI; http serves the same file from 127.0.0.1 on this phone.") {
                spikeButton("Video file", icon: "play.rectangle") { viewModel.runVideoFile() }
                HermesDivider()
                spikeButton("Video http", icon: "network") { viewModel.runVideoHTTP() }
                HermesDivider()
                Button { viewModel.stopVideo() } label: {
                    HermesRow("Stop video", icon: "stop.circle", mutedIcon: true, showsChevron: false)
                }
                .buttonStyle(.plain)
            }
            HermesSection(header: "Card latency",
                          footer: "Ten 600 x 600 image cards; logs min, median and max send time. Over 400 ms median means deck rotation becomes a short clip.") {
                spikeButton("Card latency", icon: "timer") { viewModel.runCardLatency() }
            }
            HermesSection(header: "Glasses speech",
                          footer: "Starts the glasses' own recognizer and puts a card on the lens. Say something, then answer whether the call screen covered the card.") {
                Button { viewModel.toggleSpeech() } label: {
                    HermesRow(viewModel.speechActive ? "Stop glasses speech" : "Glasses speech",
                              icon: "waveform", mutedIcon: true, showsChevron: false)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.speechActive && viewModel.running != nil)
                if viewModel.awaitingCallScreenAnswer {
                    HermesDivider()
                    HStack(spacing: 12) {
                        HermesPrimaryButton(title: "Call screen: Yes") { viewModel.answerCallScreen(appeared: true) }
                        HermesPrimaryButton(title: "Call screen: No") { viewModel.answerCallScreen(appeared: false) }
                    }
                    .padding(16)
                }
            }
            HermesSection(header: "Inputs", footer: "Logs every glasses input event for 20 s.") {
                spikeButton("Inputs", icon: "hand.draw") { viewModel.runInputs() }
            }
            HermesSection(header: "Results") {
                if viewModel.results.isEmpty {
                    HermesRow("Nothing yet", showsChevron: false)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                    .textSelection(.enabled)
                    HermesDivider()
                    Button { viewModel.clearResults() } label: {
                        HermesRow("Clear results", icon: "trash", mutedIcon: true, showsChevron: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Showcase spikes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func spikeButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HermesRow(title, icon: icon, mutedIcon: true,
                      value: viewModel.running == title ? "Running" : nil, showsChevron: false)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.running != nil)
    }
}
