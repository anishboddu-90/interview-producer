import sys
from interview_producer.app import main
try:
    raise SystemExit(main())
except Exception:
    if "--smoke-test" in sys.argv:
        # Avoid a modal traceback dialog hanging an unattended package check.
        import tempfile, traceback
        from pathlib import Path
        Path(tempfile.gettempdir(),"interview-producer-smoke-failure.txt").write_text(traceback.format_exc(),encoding="utf-8")
        raise SystemExit(1)
    raise
