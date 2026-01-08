#!/usr/bin/env python3
"""
Test script to replicate the exact environment that Swift uses
"""

import sys
import os

print("🧪 Testing Swift environment simulation...")
print(f"Python executable: {sys.executable}")
print(f"Python version: {sys.version}")
print(f"Current working directory: {os.getcwd()}")

print("\n📂 Python path:")
for i, path in enumerate(sys.path):
    print(f"  {i+1}. {path}")

print(f"\n🌍 PYTHONPATH environment variable: {os.environ.get('PYTHONPATH', 'Not set')}")

print("\n🔍 Testing imports...")

try:
    import greenlet
    print("✅ greenlet import successful")
    
    # Test the specific failing import
    from greenlet import _greenlet
    print("✅ greenlet._greenlet import successful")
    
except ImportError as e:
    print(f"❌ greenlet import failed: {e}")
    print("🔍 Checking greenlet installation...")
    
    # Try to find where greenlet is installed
    try:
        import greenlet
        print(f"   Greenlet file: {greenlet.__file__}")
    except:
        print("   Greenlet not found at all")

try:
    from playwright.async_api import async_playwright
    print("✅ playwright import successful")
except ImportError as e:
    print(f"❌ playwright import failed: {e}")

print("\n✅ Environment test complete!")