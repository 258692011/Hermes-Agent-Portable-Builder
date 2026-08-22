import os
import site

site_packages = os.environ.get("HERMES_PORTABLE_SITE_PACKAGES")
if site_packages and os.path.isdir(site_packages):
    site.addsitedir(site_packages)
