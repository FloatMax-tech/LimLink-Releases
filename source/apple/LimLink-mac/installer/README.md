# Direct Mac installer layout

`layout.py` draws a compact 640×440 installation surface with 1×/2× TIFF representations, then writes `bwsp`, `icvp`, `icvl`, `vSrn` and two `Iloc` Finder records. The unified installer uses Chinese primary text and English secondary instructions. The offline HTML guide contains nine languages and is placed beside the DMG in the installer ZIP, keeping the disk image to two visible installation icons.

The background alias must be created **inside the mounted writable image**. A host-staging alias would point to the wrong filesystem/CNID. The helper refuses a non-mounted destination. `package-direct.sh` copies an already signed/stapled app to a fresh image, writes only image-level artwork/metadata, verifies the app again, detaches only its own temporary mount, converts to UDZO, and verifies the image. It does not build, run, sign or notarize an app or notarize the new disk image.

Requirements: Python with Pillow, `ds_store==1.3.3` and `mac_alias==2.2.3`; macOS Hiragino Sans GB and Helvetica Neue fonts; Apple packaging/signature tools. Set `LIMLINK_PACKAGING_PYTHON` for a prepared Python environment and `PYTHONPATH` for an existing dependency directory if needed. The packaging script accepts the same absolute app/output paths as before and refuses existing channel artifacts. Its existing universal-architecture check is retained.

Each ZIP contains a folder with its DMG, offline installation guide and a README identifying the actual app build and packaging-only status. Platform manifests still describe the DMG. No signed app file is edited. Layout is reproducible from source; volume IDs/dates and resulting archive hashes are fresh for each packaging run.
