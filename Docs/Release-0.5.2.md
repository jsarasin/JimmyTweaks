Jimmy Tweaks V0.5.2 for **Apple silicon Macs running macOS 27 or later**.

- Fixed optional closed-lid helper update failures preventing the whole app from opening. Other features now remain available while helper recovery is unresolved.
- Added cause-specific recovery: approval opens Login Items, incompatible signatures require a compatible installation, and unexplained timeouts or connection failures disable closed-lid support until a successful reset.
- Protected worker cleanup with conservative recovery-state checks and a bounded, read-only sleep-state probe. Power actions pause while restoration is unresolved; recovery data and settings are retained when cleanup fails.
- Improved helper executable-location detection, startup diagnostics, replacement verification, and launchd restart behavior.
- Added **Absorbed Icons** to the J menu with named icons, separate entries for multiple status items, and direct access to each application's original controls.
- Added visible column headers to shortcut management and action selection, with clearer action-picker sizing and borders.

### Download and install

Download `Jimmy-Tweaks-0.5.2-macos-arm64.zip`, extract it, and move **Jimmy Tweaks.app** to Applications. Read `INSTALL.txt`, open the app from Applications, and follow the permission guidance. Verify the archive against `SHA256SUMS.txt`.

**Signing:** This optimized Release build is ad-hoc signed and is **not Developer ID signed or notarized**. macOS may block opening it. Automatic login registration is unavailable. Approved closed-lid helper installation requires a properly signed/notarized distribution; ordinary idle-sleep prevention does not require that helper. Icon Absorber remains experimental.

Normal upgrades preserve preferences, shortcuts, and recurring requests. **Reset Permissions and Uninstall Workers** removes saved app data and registrations after required recovery and cleanup succeed; it also clears persisted helper disablement. It is a full reset, not a helper-only repair.

### Validation

Focused Awake & Sleep, worker lifecycle, persistent disablement, safe cleanup, timeout/reply races, and degraded Settings checks passed. Recovery-state Settings were rendered and reviewed at 960 and 780 points. Development and optimized Release builds, strict app/helper signature checks, source boundaries, and release archive verification passed.

Also passed 7,745 core checks and the complete native UI regression run: engine/AX recovery and shutdown, 171 permission checks, 185 shortcut checks, loopback HTTP and request scheduling/persistence, Settings, Icon Absorber preview/J-menu behavior, 107 Snow Storm checks, 198 Christmas checks, 87 Fireplace checks, 106 desktop interaction checks, and ten-page UI smoke/navigation. The earlier shortcut-recorder assertion did not recur in the release verification run; no shortcut-recorder source or fixture was changed.

The original daemon's exit-code-1 cause and real closed-lid hardware behavior still require verification with a Developer ID signed, notarized installation. This release does not claim production daemon certification. See `VALIDATION.md` for detailed checks and limitations.
