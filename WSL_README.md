# Windows Subsystem for Linux (WSL)

Windows Subsystem for Linux (WSL) allows you to run a Linux environment directly on Windows, without the need for a virtual machine or dual-boot setup. WSL is ideal for developers who want to use Linux tools alongside their Windows workflow.

## Benefits of WSL

- Run Linux command-line tools natively on Windows.
- Access Windows files from Linux and vice versa.
- Use popular Linux distributions like Ubuntu, Debian, and more.

## Getting Started with WSL and Ubuntu

### 1. Enable WSL

Open PowerShell as Administrator and run:

```powershell
wsl --install
```

This command installs WSL and the default Linux distribution (usually Ubuntu). If you want a specific version, use:

```powershell
wsl --install -d Ubuntu
```

### 2. Set Up Ubuntu

After installation, restart your computer if prompted. Then, launch Ubuntu from the Start menu. The first time you run it, you'll be asked to create a new UNIX username and password.

### 3. Update Ubuntu

Once inside Ubuntu, update your package lists:

```bash
sudo apt update && sudo apt upgrade
```

### 4. Start Using WSL

You can now use Linux commands, install packages, and develop using your preferred tools.

### 5. Accessing Files

- Linux files: `/home/<your-username>`
- Windows files: `/mnt/c/Users/<your-windows-username>`

## Useful Commands

- List installed distributions: `wsl --list --verbose`
- Set default distribution: `wsl --set-default <DistroName>`
- Launch WSL: Search for "Ubuntu" in the Start menu or run `wsl` in PowerShell.

## Resources

- [Microsoft WSL Documentation](https://docs.microsoft.com/en-us/windows/wsl/)
- [Ubuntu on WSL](https://ubuntu.com/wsl)
