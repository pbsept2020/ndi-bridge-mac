# NDI Bridge Receiver - Windows Setup Script
# Run this in PowerShell as Administrator

Write-Host "=" * 50
Write-Host "NDI Bridge Receiver - Windows Setup"
Write-Host "=" * 50

# Check Python
Write-Host "`n[1/4] Checking Python..."
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "ERROR: Python not found. Install from https://python.org"
    exit 1
}
python --version

# Check FFmpeg
Write-Host "`n[2/4] Checking FFmpeg..."
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    Write-Host "WARNING: FFmpeg not found. Install it:"
    Write-Host "  winget install Gyan.FFmpeg"
    Write-Host "  Or download from https://ffmpeg.org"
}
else {
    ffmpeg -version 2>&1 | Select-Object -First 1
}

# Check NDI Runtime
Write-Host "`n[3/4] Checking NDI Runtime..."
$ndiPath = "C:\Program Files\NDI\NDI 6 Runtime\bin\x64"
if (Test-Path $ndiPath) {
    Write-Host "NDI Runtime found at: $ndiPath"
}
else {
    Write-Host "WARNING: NDI Runtime not found."
    Write-Host "  Download from https://ndi.video/tools/"
    Write-Host "  Install 'NDI 6 Tools' or 'NDI Runtime'"
}

# Install Python dependencies
Write-Host "`n[4/4] Installing Python dependencies..."
pip install --upgrade pip
pip install cyndilib numpy

Write-Host "`n" + "=" * 50
Write-Host "Setup complete!"
Write-Host "=" * 50
Write-Host "`nTo run the receiver:"
Write-Host "  python receiver_cyndilib.py --port 5990 --name `"NDI Bridge EC2`""
Write-Host "`nMake sure:"
Write-Host "  - UDP port 5990 is open in Windows Firewall"
Write-Host "  - UDP port 5990 is open in AWS Security Group"
Write-Host "  - NDI Runtime is installed"
