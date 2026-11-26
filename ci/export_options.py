"""Render the manual signing options for both targets."""
import os
import plistlib
import sys
from pathlib import Path

options = plistlib.loads(Path(__file__).with_name("ExportOptions.plist").read_bytes())
app_id = os.environ.get("APP_ID", "com.hgsldswk.braglog")
options["teamID"] = os.environ["TEAM_ID"]
options["provisioningProfiles"] = {
    app_id: os.environ.get("APP_PROFILE", "BragLog AppStore"),
    app_id + ".widget": os.environ.get("WIDGET_PROFILE", "BragLog Widget AppStore"),
}
sys.stdout.buffer.write(plistlib.dumps(options))
