// ==============================================================================
// event_mixer_multisource.cc - Multi-source HepMC event mixer
// ==============================================================================
// Merges events from multiple HepMC3 input files into single combined events.
// Supports 1 (passthrough), 2 (DPS), or 3+ (TPS/NPS) input sources.
// Outputs HepMC2 format for CMSSW compatibility.
//
// Key features:
// - Handles variable number of input sources (1 to N)
// - Preserves particle barcodes with offsets to avoid conflicts
// - Properly merges event weights
// - Uses phi-source event count as reference (typically has fewer events)
//
// Compilation (in CMSSW environment):
//   g++ -std=c++17 -O2 event_mixer_multisource.cc -o event_mixer_multisource \
//       -I$HEPMC3/include -I$HEPMC2/include \
//       -L$HEPMC3/lib64 -L$HEPMC2/lib \
//       -Wl,-rpath,$HEPMC3/lib64 -Wl,-rpath,$HEPMC2/lib \
//       -lHepMC3 -lHepMC
//
// Usage:
//   ./event_mixer_multisource output.hepmc input1.hepmc [input2.hepmc ...] [--nevents N]
// ==============================================================================

#include "HepMC3/GenEvent.h"
#include "HepMC3/GenParticle.h"
#include "HepMC3/GenVertex.h"
#include "HepMC3/ReaderAscii.h"
#include "HepMC3/Print.h"

#include "HepMC/GenEvent.h"
#include "HepMC/GenParticle.h"
#include "HepMC/GenVertex.h"
#include "HepMC/IO_GenEvent.h"

#include <iostream>
#include <fstream>
#include <vector>
#include <memory>
#include <map>
#include <algorithm>

using namespace std;

// Convert HepMC3 event to HepMC2 event
HepMC::GenEvent* convertToHepMC2(const HepMC3::GenEvent& evt3, int eventNumber, int barcodeOffset = 0) {
    HepMC::GenEvent* evt2 = new HepMC::GenEvent();
    evt2->set_event_number(eventNumber);
    evt2->set_signal_process_id(0);
    
    // Set weight
    if (evt3.weights().size() > 0) {
        evt2->weights().push_back(evt3.weights()[0]);
    } else {
        evt2->weights().push_back(1.0);
    }
    
    // Particle mapping
    map<int, HepMC::GenParticle*> particleMap;
    
    // Create all particles
    for (const auto& p3 : evt3.particles()) {
        HepMC::FourVector mom(p3->momentum().px(), 
                              p3->momentum().py(),
                              p3->momentum().pz(),
                              p3->momentum().e());
        HepMC::GenParticle* p2 = new HepMC::GenParticle(mom, p3->pid(), p3->status());
        p2->suggest_barcode(p3->id() + barcodeOffset);
        particleMap[p3->id()] = p2;
    }
    
    // Create vertices and connect particles
    for (const auto& v3 : evt3.vertices()) {
        HepMC::FourVector pos(v3->position().x(),
                              v3->position().y(),
                              v3->position().z(),
                              v3->position().t());
        HepMC::GenVertex* v2 = new HepMC::GenVertex(pos);
        v2->suggest_barcode(v3->id() - barcodeOffset);
        
        for (const auto& p3_in : v3->particles_in()) {
            if (particleMap.count(p3_in->id())) {
                v2->add_particle_in(particleMap[p3_in->id()]);
            }
        }
        
        for (const auto& p3_out : v3->particles_out()) {
            if (particleMap.count(p3_out->id())) {
                v2->add_particle_out(particleMap[p3_out->id()]);
            }
        }
        
        evt2->add_vertex(v2);
    }
    
    return evt2;
}

// Merge multiple HepMC3 events into one HepMC2 event
HepMC::GenEvent* mergeEvents(const vector<HepMC3::GenEvent*>& events, int eventNumber) {
    HepMC::GenEvent* merged = new HepMC::GenEvent();
    merged->set_event_number(eventNumber);
    merged->set_signal_process_id(0);
    
    // Combine weights (product of all event weights)
    double combinedWeight = 1.0;
    for (const auto& evt : events) {
        if (evt && evt->weights().size() > 0) {
            combinedWeight *= evt->weights()[0];
        }
    }
    merged->weights().push_back(combinedWeight);
    
    // Barcode offset for each source
    const int barcodeStep = 100000;
    
    for (size_t srcIdx = 0; srcIdx < events.size(); ++srcIdx) {
        if (!events[srcIdx]) continue;
        
        const HepMC3::GenEvent& evt = *events[srcIdx];
        int offset = srcIdx * barcodeStep;
        
        // Particle mapping for this source
        map<int, HepMC::GenParticle*> particleMap;
        
        // Create particles
        for (const auto& p3 : evt.particles()) {
            HepMC::FourVector mom(p3->momentum().px(), 
                                  p3->momentum().py(),
                                  p3->momentum().pz(),
                                  p3->momentum().e());
            HepMC::GenParticle* p2 = new HepMC::GenParticle(mom, p3->pid(), p3->status());
            p2->suggest_barcode(p3->id() + offset);
            particleMap[p3->id()] = p2;
        }
        
        // Create vertices
        for (const auto& v3 : evt.vertices()) {
            HepMC::FourVector pos(v3->position().x(),
                                  v3->position().y(),
                                  v3->position().z(),
                                  v3->position().t());
            HepMC::GenVertex* v2 = new HepMC::GenVertex(pos);
            v2->suggest_barcode(v3->id() - offset);
            
            for (const auto& p3_in : v3->particles_in()) {
                if (particleMap.count(p3_in->id())) {
                    v2->add_particle_in(particleMap[p3_in->id()]);
                }
            }
            
            for (const auto& p3_out : v3->particles_out()) {
                if (particleMap.count(p3_out->id())) {
                    v2->add_particle_out(particleMap[p3_out->id()]);
                }
            }
            
            merged->add_vertex(v2);
        }
    }
    
    return merged;
}

// Count specific particles in event
void countParticles(const HepMC::GenEvent* evt, int& nJpsi, int& nUpsilon, int& nPhi) {
    nJpsi = 0;
    nUpsilon = 0;
    nPhi = 0;
    
    for (auto p = evt->particles_begin(); p != evt->particles_end(); ++p) {
        int pid = abs((*p)->pdg_id());
        if (pid == 443) nJpsi++;
        else if (pid == 553 || pid == 100553 || pid == 200553) nUpsilon++;
        else if (pid == 333) nPhi++;
    }
}

void printUsage(const char* progName) {
    cerr << "\n=== Multi-Source HepMC Event Mixer ===" << endl;
    cerr << "Usage: " << progName << " output.hepmc input1.hepmc [input2.hepmc ...] [--nevents N]" << endl;
    cerr << "\nArguments:" << endl;
    cerr << "  output.hepmc  : Output merged HepMC file" << endl;
    cerr << "  input1.hepmc  : First input HepMC file" << endl;
    cerr << "  inputN.hepmc  : Additional input files (optional)" << endl;
    cerr << "  --nevents N   : Maximum events to process (default: all)" << endl;
    cerr << "\nExamples:" << endl;
    cerr << "  # Single source (passthrough with HepMC2 conversion):" << endl;
    cerr << "  " << progName << " output.hepmc phi.hepmc" << endl;
    cerr << "\n  # DPS (two sources):" << endl;
    cerr << "  " << progName << " output.hepmc normal.hepmc phi.hepmc" << endl;
    cerr << "\n  # TPS (three sources):" << endl;
    cerr << "  " << progName << " output.hepmc src1.hepmc src2.hepmc src3.hepmc" << endl;
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        printUsage(argv[0]);
        return 1;
    }
    
    // Parse arguments
    string outputFile = argv[1];
    vector<string> inputFiles;
    int nEvents = -1;
    
    for (int i = 2; i < argc; ++i) {
        string arg = argv[i];
        if (arg == "--nevents" && i + 1 < argc) {
            nEvents = atoi(argv[++i]);
        } else if (arg[0] != '-') {
            inputFiles.push_back(arg);
        }
    }
    
    if (inputFiles.empty()) {
        cerr << "Error: No input files specified" << endl;
        return 1;
    }
    
    int nSources = inputFiles.size();
    
    cout << "\n=== Multi-Source HepMC Event Mixer ===" << endl;
    cout << "Output:     " << outputFile << endl;
    cout << "N sources:  " << nSources << endl;
    for (size_t i = 0; i < inputFiles.size(); ++i) {
        cout << "  Input " << i+1 << ": " << inputFiles[i] << endl;
    }
    cout << "N events:   " << (nEvents > 0 ? to_string(nEvents) : "all") << endl;
    cout << "========================================\n" << endl;
    
    // Open input files
    vector<unique_ptr<HepMC3::ReaderAscii>> readers;
    for (const auto& file : inputFiles) {
        auto reader = make_unique<HepMC3::ReaderAscii>(file);
        if (reader->failed()) {
            cerr << "Error: Cannot open input file: " << file << endl;
            return 1;
        }
        readers.push_back(std::move(reader));
    }
    
    // Open output file
    ofstream outStream(outputFile);
    if (!outStream.is_open()) {
        cerr << "Error: Cannot open output file: " << outputFile << endl;
        return 1;
    }
    HepMC::IO_GenEvent writer(outStream);
    
    // Process events
    int iEvent = 0;
    int totalJpsi = 0, totalUpsilon = 0, totalPhi = 0;
    
    cout << "Processing events..." << endl;
    
    while (true) {
        if (nEvents > 0 && iEvent >= nEvents) break;
        
        // Read one event from each source
        vector<HepMC3::GenEvent*> events(nSources, nullptr);
        bool allValid = true;
        
        for (int i = 0; i < nSources; ++i) {
            events[i] = new HepMC3::GenEvent();
            if (!readers[i]->read_event(*events[i]) || readers[i]->failed()) {
                allValid = false;
                delete events[i];
                events[i] = nullptr;
            }
        }
        
        if (!allValid) {
            // Clean up and exit
            for (auto evt : events) {
                if (evt) delete evt;
            }
            cout << "Reached end of at least one input file." << endl;
            break;
        }
        
        // Merge events
        HepMC::GenEvent* merged;
        if (nSources == 1) {
            merged = convertToHepMC2(*events[0], iEvent);
        } else {
            merged = mergeEvents(events, iEvent);
        }
        
        // Count particles
        int nJpsi, nUpsilon, nPhi;
        countParticles(merged, nJpsi, nUpsilon, nPhi);
        totalJpsi += nJpsi;
        totalUpsilon += nUpsilon;
        totalPhi += nPhi;
        
        // Write output
        writer.write_event(merged);
        
        // Cleanup
        for (auto evt : events) {
            if (evt) delete evt;
        }
        delete merged;
        
        ++iEvent;
        if (iEvent % 100 == 0) {
            cout << "Merged " << iEvent << " events..." << endl;
        }
    }
    
    outStream.close();
    
    cout << "\n========================================" << endl;
    cout << "Mixing Summary:" << endl;
    cout << "----------------------------------------" << endl;
    cout << "Total events merged: " << iEvent << endl;
    cout << "Particle counts:" << endl;
    cout << "  Total J/psi:   " << totalJpsi << endl;
    cout << "  Total Upsilon: " << totalUpsilon << endl;
    cout << "  Total phi:     " << totalPhi << endl;
    cout << "----------------------------------------" << endl;
    cout << "Output file: " << outputFile << endl;
    cout << "========================================" << endl;
    
    return 0;
}
