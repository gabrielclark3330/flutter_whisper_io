import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import 'generated_bindings.dart';

import 'package:flutter/material.dart';
import 'package:audio_streamer/audio_streamer.dart';

import 'package:flutter/services.dart';

void main() {
  runApp(new MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Note that AudioStreamer works as a singleton.
  AudioStreamer streamer = AudioStreamer();

  bool _isRecording = false;
  List<double> _audio = [];
  double secondsRecorded = 0;
  int sampleRate = 0;
  var dylib = null;
  var nativeLib = null;
  String translatedText = "";

  @override
  void initState() {
    super.initState();
    // Initialize dynamic library containing libsamplerate and whisper functions
    dylib = ffi.DynamicLibrary.process();
    nativeLib = NativeLibrary(dylib);
  }

  List<double> downSamplePCM(
      List<double> pcmArray, inputSampleRate, outputSampleRate) {
    ffi.Pointer<ffi.Float> input_data;
    ffi.Pointer<ffi.Float> output_data;

    int input_frames = pcmArray.length;
    int output_frames; // We'll compute this below

    // Copy the float values to the unmanaged memory.
    input_data = calloc<ffi.Float>(input_frames);
    for (var i = 0; i < pcmArray.length; i++) {
      input_data.elementAt(i).value = pcmArray[i];
    }

    // Calculate necessary output buffer size
    double conversion_factor = 16000 / sampleRate;
    output_frames = (input_frames * conversion_factor).toInt();
    output_data = calloc<ffi.Float>(output_frames);

    ffi.Pointer<SRC_DATA> src_data = calloc<SRC_DATA>();
    src_data.ref.data_in = input_data;
    src_data.ref.input_frames = input_frames;
    src_data.ref.data_out = output_data;
    src_data.ref.output_frames = output_frames;
    src_data.ref.src_ratio = conversion_factor;

    int error = nativeLib.src_simple(
        src_data, 4, 1); //(data, poor quality linear converter, 1 channel)
    // Using SINC best quality converter and 1 channel (mono)
    if (error != 0) {
      print("Error converting: ${error}");
    }

    List<double> resampledOutput = [];
    for (int i = 0; i < src_data.ref.output_frames_gen; i++) {
      resampledOutput.add(src_data.ref.data_out.elementAt(i).value);
    }

    calloc.free(input_data);
    calloc.free(output_data);
    calloc.free(src_data);
    return resampledOutput;
  }

  void translateTextFromPCM(List<double> pcmArray) {
    List<double> resampledOutput = downSamplePCM(_audio, sampleRate, 16000);

    // Copy the float values to the unmanaged memory.
    ffi.Pointer<ffi.Float> resampled_data =
        calloc<ffi.Float>(resampledOutput.length);
    for (var i = 0; i < resampledOutput.length; i++) {
      resampled_data.elementAt(i).value = resampledOutput[i];
    }

    String modelPath =
        "/Users/gabrielclark/Documents/projects/flutter_whisper_io/ios/Classes/whisper.cpp/models/ggml-base.en.bin";
    final pathPointer = modelPath.toNativeUtf8().cast<ffi.Char>();
    final ctx = nativeLib.whisper_init_from_file(pathPointer);
    var wparams = nativeLib.whisper_full_default_params(
        whisper_sampling_strategy.WHISPER_SAMPLING_GREEDY);

    final result = nativeLib.whisper_full(
        ctx, wparams, resampled_data, resampledOutput.length); //_audio.length
    if (result != 0) {
      print('failed to process audio');
      //return "failed to process audio";
    }

    String internalTranslatedText = "";
    final nSegments = nativeLib.whisper_full_n_segments(ctx);
    for (var i = 0; i < nSegments; i++) {
      final segmentText = nativeLib.whisper_full_get_segment_text(ctx, i);
      ffi.Pointer<ffi.Char> charPtf =
          ffi.Pointer.fromAddress(segmentText.address);
      // print text from char pointer
      var segmentTextIndex = 0;
      while (charPtf.elementAt(segmentTextIndex).value != 0 &&
          segmentTextIndex < 100) {
        internalTranslatedText = internalTranslatedText +
            String.fromCharCode(charPtf.elementAt(segmentTextIndex).value);
        //print(String.fromCharCode(charPtf.elementAt(segmentTextIndex).value));
        segmentTextIndex = segmentTextIndex + 1;
      }
    }

    setState(() {
      translatedText = internalTranslatedText;
    });
    print(translatedText);

    // After using the context, make sure you free the allocated memory:
    calloc.free(resampled_data);
    malloc.free(pathPointer);
    nativeLib.whisper_free(ctx);
  }

  void onAudio(List<double> buffer) async {
    _audio.addAll(buffer);
    sampleRate = await streamer.actualSampleRate;
    print(sampleRate);
    setState(() {
      secondsRecorded = _audio.length.toDouble() / sampleRate;
    });
  }

  void handleError(PlatformException error) {
    setState(() {
      _isRecording = false;
    });
    print(error.message);
    print(error.details);
  }

  void start() async {
    try {
      print("start");
      // start streaming using default sample rate of 44100 Hz
      streamer.start(onAudio, handleError);

      setState(() {
        _isRecording = true;
      });
    } catch (error) {
      print(error);
    }
  }

  void stop() async {
    bool stopped = await streamer.stop();
    translateTextFromPCM(_audio);
    setState(() {
      _isRecording = stopped;
    });
  }

  List<Widget> getContent() => <Widget>[
        Container(
          margin: EdgeInsets.all(25),
          child: Column(
            children: [
              Container(
                child: Text(_isRecording ? "Mic: ON" : "Mic: OFF",
                    style: TextStyle(fontSize: 25, color: Colors.blue)),
                margin: EdgeInsets.only(top: 20),
              ),
              Container(
                child: Text('$secondsRecorded seconds recorded.'),
                margin: EdgeInsets.only(top: 20),
              ),
              Container(
                child: Text('Translated text: $translatedText'),
                margin: EdgeInsets.only(top: 20),
              ),
            ],
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: getContent())),
        floatingActionButton: FloatingActionButton(
          backgroundColor: _isRecording ? Colors.red : Colors.green,
          onPressed: _isRecording ? stop : start,
          child: _isRecording ? Icon(Icons.stop) : Icon(Icons.mic),
        ),
      ),
    );
  }
}
