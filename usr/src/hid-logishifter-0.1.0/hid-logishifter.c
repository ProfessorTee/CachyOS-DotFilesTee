// SPDX-License-Identifier: GPL-2.0-only
/*
 * hid-logishifter.c - Custom HID driver for InterBiometrics Logitech@ Shifter
 *
 * Target device:
 *   USB VID:PID 1209:f00d
 *   HID name: "InterBiometrics Logitech@ Shifter"
 *
 * 12-byte HID report layout (report ID 0x01):
 *   byte[0]    = report ID (0x01)
 *   byte[1]    = padding / unknown
 *   byte[2:3]  = gear bits (LE, one-hot):
 *                 0x0000=neutral, 0x0001=G1, 0x0002=G2, 0x0004=G3,
 *                 0x0008=G4, 0x0010=G5, 0x0020=G6, 0x0040=R
 *   byte[4:5]  = X axis (LE, signed 16-bit) — lane: left/center/right
 *   byte[6:7]  = Y axis (LE, signed 16-bit) — row: up/down
 *   byte[8:11] = reserved / padding
 *
 * H-pattern gear layout (physical):
 *        1   3   5
 *        |   |   |
 *        +---N---+---+
 *        |   |   |   |
 *        2   4   6   R
 *
 * X axis determines lane:  low = left (1,2), mid = center (3,4), high = right (5,6,R)
 * Y axis determines row:   low = odd gears (1,3,5), high = even gears (2,4,6,R)
 */

#include <linux/device.h>
#include <linux/hid.h>
#include <linux/input.h>
#include <linux/kernel.h>
#include <linux/module.h>

#define HID_LOGISHIFTER_VID 0x1209
#define HID_LOGISHIFTER_PID 0xF00D

#define LOGISHIFTER_REPORT_ID_MAIN 0x01
#define LOGISHIFTER_REPORT_MIN_SIZE 4

#define LOGISHIFTER_BIT_GEAR_1 0x0001
#define LOGISHIFTER_BIT_GEAR_2 0x0002
#define LOGISHIFTER_BIT_GEAR_3 0x0004
#define LOGISHIFTER_BIT_GEAR_4 0x0008
#define LOGISHIFTER_BIT_GEAR_5 0x0010
#define LOGISHIFTER_BIT_GEAR_6 0x0020
#define LOGISHIFTER_BIT_GEAR_R 0x0040

#define LOGISHIFTER_ALL_BITS (LOGISHIFTER_BIT_GEAR_1 | \
			      LOGISHIFTER_BIT_GEAR_2 | \
			      LOGISHIFTER_BIT_GEAR_3 | \
			      LOGISHIFTER_BIT_GEAR_4 | \
			      LOGISHIFTER_BIT_GEAR_5 | \
			      LOGISHIFTER_BIT_GEAR_6 | \
			      LOGISHIFTER_BIT_GEAR_R)

#define LOGISHIFTER_BUTTON_1 BTN_TRIGGER
#define LOGISHIFTER_BUTTON_2 BTN_THUMB
#define LOGISHIFTER_BUTTON_3 BTN_THUMB2
#define LOGISHIFTER_BUTTON_4 BTN_TOP
#define LOGISHIFTER_BUTTON_5 BTN_TOP2
#define LOGISHIFTER_BUTTON_6 BTN_PINKIE
#define LOGISHIFTER_BUTTON_7 BTN_BASE

struct logishifter_drvdata {
	struct input_dev *input;
	u16 last_bits;
};

/*
 * Determine gear from X/Y axes.
 *
 * The adapter's own gear bits misdetect the center lane (3/4 reported as
 * 1/2/5), so gears 1-6 come from the raw axes.  Measured 2026-10-12:
 *   X lanes: left ~950, center ~1900, right ~2800
 *   Y rows:  top ~3650, neutral ~2000, bottom ~300
 * Thresholds are module params, tunable live via
 * /sys/module/hid_logishifter/parameters/.
 */
static int x_left_max = 1400;
module_param(x_left_max, int, 0644);
MODULE_PARM_DESC(x_left_max, "X at or below = left lane (1/2)");

static int x_right_min = 2400;
module_param(x_right_min, int, 0644);
MODULE_PARM_DESC(x_right_min, "X at or above = right lane (5/6/R)");

static int y_top_min = 2600;
module_param(y_top_min, int, 0644);
MODULE_PARM_DESC(y_top_min, "Y at or above = top row (1/3/5)");

static int y_bottom_max = 1400;
module_param(y_bottom_max, int, 0644);
MODULE_PARM_DESC(y_bottom_max, "Y at or below = bottom row (2/4/6/R)");

#define LOGISHIFTER_BOTTOM_ROW (LOGISHIFTER_BIT_GEAR_2 | \
				LOGISHIFTER_BIT_GEAR_4 | \
				LOGISHIFTER_BIT_GEAR_6)

static u16 logishifter_bits_from_axes(s16 x, s16 y, u16 last)
{
	bool bottom;

	if (y >= y_top_min)
		bottom = false;
	else if (y <= y_bottom_max)
		bottom = true;
	else
		return 0; /* neutral */

	/*
	 * Lane changes go through neutral.  X drifts toward the next lane
	 * while the lever springs out of a gate, so keep the latched gear
	 * as long as Y stays in its row.
	 */
	if (last && !!(last & LOGISHIFTER_BOTTOM_ROW) == bottom)
		return last;

	if (x <= x_left_max)
		return bottom ? LOGISHIFTER_BIT_GEAR_2 : LOGISHIFTER_BIT_GEAR_1;
	if (x >= x_right_min)
		return bottom ? LOGISHIFTER_BIT_GEAR_6 : LOGISHIFTER_BIT_GEAR_5;
	return bottom ? LOGISHIFTER_BIT_GEAR_4 : LOGISHIFTER_BIT_GEAR_3;
}

static void logishifter_report_state(struct input_dev *input, u16 bits)
{
	input_report_key(input, LOGISHIFTER_BUTTON_1, !!(bits & LOGISHIFTER_BIT_GEAR_1));
	input_report_key(input, LOGISHIFTER_BUTTON_2, !!(bits & LOGISHIFTER_BIT_GEAR_2));
	input_report_key(input, LOGISHIFTER_BUTTON_3, !!(bits & LOGISHIFTER_BIT_GEAR_3));
	input_report_key(input, LOGISHIFTER_BUTTON_4, !!(bits & LOGISHIFTER_BIT_GEAR_4));
	input_report_key(input, LOGISHIFTER_BUTTON_5, !!(bits & LOGISHIFTER_BIT_GEAR_5));
	input_report_key(input, LOGISHIFTER_BUTTON_6, !!(bits & LOGISHIFTER_BIT_GEAR_6));
	input_report_key(input, LOGISHIFTER_BUTTON_7, !!(bits & LOGISHIFTER_BIT_GEAR_R));

	input_sync(input);
}

static int logishifter_raw_event(struct hid_device *hdev,
			     struct hid_report *report,
			     u8 *data, int size)
{
	struct logishifter_drvdata *drvdata = hid_get_drvdata(hdev);
	struct input_dev *input;
	int p; /* payload offset */
	u16 bits;
	s16 x, y;

	if (!drvdata || !drvdata->input)
		return 0;

	if (size < 4)
		return 0;

	/* Report ID present? */
	if (data[0] == LOGISHIFTER_REPORT_ID_MAIN)
		p = 1;
	else
		p = 0;

	if (size < p + 7)
		return 0;

	input = drvdata->input;

	/* Gear bits: payload[1:2] little-endian, one-hot. */
	bits = ((u16)data[p + 1] | ((u16)data[p + 2] << 8))
	       & LOGISHIFTER_ALL_BITS;

	/* X axis: payload[3:4], Y axis: payload[5:6] (LE signed). */
	x = (s16)((u16)data[p + 3] | ((u16)data[p + 4] << 8));
	y = (s16)((u16)data[p + 5] | ((u16)data[p + 6] << 8));

	hid_dbg(hdev, "bits=0x%04x x=%d y=%d raw=%*ph\n",
		 bits, x, y, min(size, 12), data);

	/*
	 * Gears 1-6 from the axes.  Reverse needs the push-down switch,
	 * which only the adapter sees, so take R from its bits.
	 */
	{
		u16 last = drvdata->last_bits;
		u16 axis_bits;

		if (last == LOGISHIFTER_BIT_GEAR_R)
			last = LOGISHIFTER_BIT_GEAR_6;
		axis_bits = logishifter_bits_from_axes(x, y, last);

		if (axis_bits == LOGISHIFTER_BIT_GEAR_6 &&
		    (bits & LOGISHIFTER_BIT_GEAR_R))
			axis_bits = LOGISHIFTER_BIT_GEAR_R;
		bits = axis_bits;
	}

	/* Report X/Y as absolute axes for diagnostics. */
	input_report_abs(input, ABS_X, x);
	input_report_abs(input, ABS_Y, y);

	if (bits != drvdata->last_bits) {
		drvdata->last_bits = bits;
		logishifter_report_state(input, bits);
	} else {
		input_sync(input);
	}

	return 1;
}

static int logishifter_probe(struct hid_device *hdev,
		     const struct hid_device_id *id)
{
	struct logishifter_drvdata *drvdata;
	struct input_dev *input;
	int ret;

	drvdata = devm_kzalloc(&hdev->dev, sizeof(*drvdata), GFP_KERNEL);
	if (!drvdata)
		return -ENOMEM;

	input = input_allocate_device();
	if (!input)
		return -ENOMEM;

	input->name = "Logitech H-Shifter (custom)";
	input->phys = hdev->phys;
	input->id.bustype = hdev->bus;
	input->id.vendor = hdev->vendor;
	input->id.product = hdev->product;
	input->id.version = hdev->version;

	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_1);
	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_2);
	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_3);
	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_4);
	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_5);
	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_6);
	input_set_capability(input, EV_KEY, LOGISHIFTER_BUTTON_7);
	input_set_abs_params(input, ABS_X, -32768, 32767, 16, 128);
	input_set_abs_params(input, ABS_Y, -32768, 32767, 16, 128);

	ret = hid_parse(hdev);
	if (ret) {
		hid_err(hdev, "hid_parse failed: %d\n", ret);
		input_free_device(input);
		return ret;
	}

	ret = hid_hw_start(hdev, HID_CONNECT_HIDRAW);
	if (ret) {
		hid_err(hdev, "hid_hw_start failed: %d\n", ret);
		input_free_device(input);
		return ret;
	}

	ret = hid_hw_open(hdev);
	if (ret) {
		hid_err(hdev, "hid_hw_open failed: %d\n", ret);
		hid_hw_stop(hdev);
		input_free_device(input);
		return ret;
	}

	ret = input_register_device(input);
	if (ret) {
		hid_err(hdev, "input_register_device failed: %d\n", ret);
		hid_hw_close(hdev);
		hid_hw_stop(hdev);
		input_free_device(input);
		return ret;
	}

	drvdata->input = input;
	drvdata->last_bits = 0;
	hid_set_drvdata(hdev, drvdata);

	hid_info(hdev, "hid-logishifter attached\n");
	return 0;
}

static void logishifter_remove(struct hid_device *hdev)
{
	struct logishifter_drvdata *drvdata = hid_get_drvdata(hdev);

	if (drvdata && drvdata->input)
		input_unregister_device(drvdata->input);

	hid_hw_close(hdev);
	hid_hw_stop(hdev);
}

static const struct hid_device_id logishifter_devices[] = {
	{ HID_USB_DEVICE(HID_LOGISHIFTER_VID, HID_LOGISHIFTER_PID) },
	{ }
};
MODULE_DEVICE_TABLE(hid, logishifter_devices);

static struct hid_driver logishifter_driver = {
	.name = "hid-logishifter",
	.id_table = logishifter_devices,
	.probe = logishifter_probe,
	.remove = logishifter_remove,
	.raw_event = logishifter_raw_event,
};

module_hid_driver(logishifter_driver);

MODULE_AUTHOR("AngryNui");
MODULE_DESCRIPTION("HID driver for InterBiometrics Logitech@ Shifter adapters");
MODULE_LICENSE("GPL");