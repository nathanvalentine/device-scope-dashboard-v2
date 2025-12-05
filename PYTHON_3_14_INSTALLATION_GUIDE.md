# Production Environment Setup - Python 3.14 Dependency Installation

## Problem
Installing Streamlit and dependencies on Python 3.14 fails when PyArrow attempts to build from source due to missing `cmake`.

## Solution
Use pre-built binary wheels instead of source builds.

### Step-by-Step Installation

**1. Upgrade pip, setuptools, and wheel:**
```powershell
cd C:\apps\device-scope-dashboard-v2
.\.venv\Scripts\python.exe -m pip install --upgrade pip setuptools wheel
```

**2. Install Streamlit with binary-only flag:**
```powershell
.\.venv\Scripts\python.exe -m pip install --only-binary :all: streamlit
```

This forces pip to use pre-built wheels and skip source compilation.

**3. Verify installation:**
```powershell
.\.venv\Scripts\streamlit run streamlit_app.py
```

### What Gets Installed
When using `--only-binary :all:`, the following packages are installed as pre-built wheels:
- streamlit 1.50.0
- pyarrow 22.0.0
- pandas 2.3.3
- numpy 2.3.5
- pillow 11.3.0
- altair 5.5.0
- All other dependencies

### Key Flags Explained

| Flag | Purpose |
|------|---------|
| `--only-binary :all:` | Use only pre-built wheels, skip source builds |
| `--upgrade` | Upgrade to latest versions |
| `-m pip` | Run pip as module (required for venv) |

### Troubleshooting

**If installation still fails with cmake error:**
1. Ensure wheel and setuptools are updated:
   ```powershell
   .\.venv\Scripts\python.exe -m pip install --upgrade wheel setuptools
   ```
2. Clear pip cache:
   ```powershell
   .\.venv\Scripts\python.exe -m pip cache purge
   ```
3. Try again with binary-only flag

**If you see "No matching distribution found":**
- Python 3.14 is very new; some packages may not have wheels yet
- Consider downgrading to Python 3.13 if wheels unavailable
- Or install cmake for source builds (requires Visual Studio Build Tools)

### Alternative: Install from requirements.txt with Binary Flag

Create or use existing `requirements.txt`, then:
```powershell
.\.venv\Scripts\python.exe -m pip install --only-binary :all: -r requirements.txt
```

### Production Deployment Notes

For Windows Service deployment:
1. Streamlit is **optional** - only needed for the dashboard UI
2. The core export script (`AllDeviceExports_Merge.ps1`) requires only PowerShell (no Python)
3. If deploying dashboard separately, use above installation steps
4. Streamlit runs on `localhost:8501` by default; configure with `streamlit_config.toml` if needed

### Testing Dashboard Launch

Once installed, verify with:
```powershell
.\.venv\Scripts\streamlit run streamlit_app.py
```

Expected output:
```
Welcome to Streamlit!

If you'd like to receive helpful onboarding emails ...
  Local URL: http://localhost:8501
```

Open http://localhost:8501 in a browser to view the dashboard.

---

**Last Updated:** December 1, 2025  
**Python Version:** 3.14.0  
**Streamlit Version:** 1.50.0
