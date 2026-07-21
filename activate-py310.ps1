# Activate conda py3.10 in this PowerShell session
& "C:\Users\108pa\miniconda3\shell\condabin\conda-hook.ps1"
conda activate py3.10
Write-Host "Active env: $env:CONDA_DEFAULT_ENV | $(python --version 2>&1)"
