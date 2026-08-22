# Quickshell brightness & gamma app

Small floating window for Hyprland with n+1 sliders:

- **Gamma (global)** — set via `hyprctl hyprsunset gamma <pct>` (starts `hyprsunset` if it is not running).
- **Per-monitor brightness** — each active monitor gets one slider:
  - integrated panels are driven with `brightnessctl`,
  - external monitors are driven over DDC/CI with `ddcutil` (VCP feature `0x10`).

Monitor discovery is fully automatic (per `hyprctl monitors -j`); values are percentages 0–100.

## Files

- `shell.qml` — entrypoint (window + layout).
- `BrightnessController.qml` — runs the backend and feeds the sliders.
- `SliderRow.qml` — label + slider row.
- `brightness-control.py` — backend: discovery, read/write for gamma, backlight, and DDC.

## Run

```sh
quickshell -c ~/.config/quickshell/brightness
```

## Dependencies

- `quickshell`, `hyprsunset`, `brightnessctl`, `ddcutil`
- the `i2c-dev` kernel module (required by `ddcutil`), e.g.:

```sh
echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf
```

## Notes / limitations

- Backlight panels are matched to monitors via the DRM connector of the sysfs
  backlight device; DDC displays are matched via the connector of their I2C bus
  (read from `/sys/bus/i2c/devices/i2c-N/name`). On NVIDIA GPUs the I2C bus
  may not carry a connector name, in which case DDC displays fall back to
  order-matching against monitors without an assigned control.
- `ddcutil` display info is cached in `/tmp/quickshell-brightness-<uid>.json`
  and re-detected when the monitor set changes.
- The current gamma cannot be read back when `hyprsunset` is not running, so
  the gamma slider initializes to 100 in that case.
