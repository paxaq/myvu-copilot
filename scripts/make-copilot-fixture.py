"""Generate a synthetic English sample locally; never plays audio aloud."""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import wave

root = Path(__file__).resolve().parent.parent
out = root / "Examples/MyvuDemo/MyvuDemo/Copilot/Resources/english-test.opusframes"
out.parent.mkdir(parents=True, exist_ok=True)
text = ("The project deadline is next Friday. The budget is twenty thousand dollars. "
        "Please clarify who owns implementation and ongoing support.")
with tempfile.TemporaryDirectory(prefix="myvu-fixture-") as temporary:
    work = Path(temporary)
    subprocess.run(["say", "-v", "Samantha", "-r", "150", "-o", str(work / "speech.aiff"), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(work / "speech.aiff"), str(work / "speech.wav")], check=True)
    with wave.open(str(work / "speech.wav")) as wav:
        assert wav.getnchannels() == 1 and wav.getframerate() == 16000 and wav.getsampwidth() == 2
        (work / "speech.pcm").write_bytes(wav.readframes(wav.getnframes()))
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "clang", "-isysroot", sdk, "-I", str(root / "Vendor/COpus.xcframework/macos-arm64_x86_64/Headers"),
                    str(root / "scripts/encode-opus-fixture.c"),
                    str(root / "Vendor/COpus.xcframework/macos-arm64_x86_64/libopus.a"),
                    "-o", str(work / "encode")], check=True)
    subprocess.run([str(work / "encode"), str(work / "speech.pcm"), str(out)], check=True)
print(f"{out}: {out.stat().st_size} bytes; SHA256 {hashlib.sha256(out.read_bytes()).hexdigest()}")
