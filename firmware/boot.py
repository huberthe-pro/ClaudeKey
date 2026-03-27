"""ClaudeKey boot config — enable USB HID keyboard + CDC data serial."""
import usb_cdc
import usb_hid

usb_cdc.enable(console=True, data=True)  # console = REPL, data = status channel
usb_hid.enable((usb_hid.Device.KEYBOARD,))
