#include <iostream>
#include <fcntl.h>
#include <io.h>
#include <shobjidl.h>
#include <vector>
#include <winrt/Windows.Media.Capture.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

// The system camera UI is owned by the VeriFin window. The image is returned
// through stdout so the ledger receives bytes, never a user's gallery path.
int CapturePhoto() {
  using namespace winrt::Windows;
  Media::Capture::CameraCaptureUI camera;
  const HWND owner = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"VeriFin");
  if (!owner) return 3;
  winrt::check_hresult(camera.as<IInitializeWithWindow>()->Initialize(owner));
  camera.PhotoSettings().Format(Media::Capture::CameraCaptureUIPhotoFormat::Jpeg);
  auto image = camera.CaptureFileAsync(Media::Capture::CameraCaptureUIMode::Photo).get();
  if (!image) return 0;
  auto buffer = Storage::FileIO::ReadBufferAsync(image).get();
  auto reader = Storage::Streams::DataReader::FromBuffer(buffer);
  std::vector<uint8_t> bytes(buffer.Length());
  reader.ReadBytes(bytes);
  _setmode(_fileno(stdout), _O_BINARY);
  std::cout.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  return 0;
}

int wmain(int argc, wchar_t** argv) {

  try {
    winrt::init_apartment();
    if (argc == 2 && std::wstring(argv[1]) == L"camera") return CapturePhoto();
    if (argc != 3 || std::wstring(argv[1]) != L"ocr") return 1;
    using namespace winrt::Windows;
    auto engine = Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages();
    if (!engine) return 2;
    auto file = Storage::StorageFile::GetFileFromPathAsync(argv[2]).get();
    auto stream = file.OpenAsync(Storage::FileAccessMode::Read).get();
    auto decoder = Graphics::Imaging::BitmapDecoder::CreateAsync(stream).get();
    auto bitmap = decoder.GetSoftwareBitmapAsync(Graphics::Imaging::BitmapPixelFormat::Bgra8,
        Graphics::Imaging::BitmapAlphaMode::Ignore).get();
    auto result = engine.RecognizeAsync(bitmap).get();
    for (const auto& line : result.Lines()) {
      std::cout << winrt::to_string(line.Text()) << '\n';
    }
    return 0;
  } catch (const winrt::hresult_error&) {
    return 3;
  }
}
