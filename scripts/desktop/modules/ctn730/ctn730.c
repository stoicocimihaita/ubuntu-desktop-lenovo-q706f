// SPDX-License-Identifier: GPL-2.0
/*
 * NXP CTN730 NFC wireless charging poller (stylus charger) - host driver
 *
 * Port of Lenovo's downstream driver (drivers/misc/ctn730/ctn730.c and
 * CTN730_i2c.c, 4.19, Lenovo Tab P12 Pro "q706f", from Lenovo's GPL kernel
 * source release) to current mainline APIs. The wire protocol and the host
 * state machine are the vendor ones; see README.md for what was changed and
 * dropped.
 *
 * Original notices: CTN730_i2c.c / CTN730_i2c.h are "Copyright (C) 2021 NXP"
 * (MODULE_AUTHOR "Michael Lee"), GPL-2.0-or-later; ctn730.c carries no
 * copyright line and is MODULE_LICENSE("GPL").
 * Mainline port: Copyright (C) 2026 Stoicoci Mihaita.
 *
 * The chip runs its own firmware ("host controlled" WLC application). The
 * host only resets it, enables charging/detection and then receives events:
 * pen detected / lost, charging state, battery level. The Bluetooth address
 * of the pen is read from the pen's NTAG through a BIST command.
 *
 * Frame format (both directions): [type|instruction] [len] [len bytes]
 *   type: 0x00 command, 0x40 response, 0x80 event
 */

#include <linux/bits.h>
#include <linux/cleanup.h>
#include <linux/completion.h>
#include <linux/crc32.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio/machine.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/miscdevice.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/property.h>
#include <linux/suspend.h>
#include <linux/mutex.h>
#include <linux/pm.h>
#include <linux/power_supply.h>
#include <linux/property.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>

/* Response status codes */
#define STATUS_OK				0x00
#define STATUS_PARAMETER_ERROR			0x01
#define STATUS_STATE_ERROR			0x02
#define STATUS_VALUE_ERROR			0x03
#define STATUS_REJECTED				0x04
#define STATUS_RESOURCE_ERROR			0x10
#define STATUS_TXLDO_ERROR			0x11
#define STATUS_ANTENNA_SELECTION_ERROR		0x12
#define STATUS_BIST_FAILED			0x20
#define STATUS_BIST_NO_WLC_CAP			0x21
#define STATUS_BIST_TXLDO_CURRENT_OVERFLOW	0x22
#define STATUS_BIST_TXLDO_CURRENT_UNDERFLOW	0x23
#define STATUS_FW_VERSION_ERROR			0x30
#define STATUS_FW_VERIFICATION_ERROR		0x31
#define STATUS_NTAG_BLOCK_PARAMETER_ERROR	0x32
#define STATUS_NTAG_READ_ERROR			0x33

#define MT_MASK			GENMASK(7, 6)
#define MT_COMMAND		0
#define MT_RESPONSE		BIT(6)
#define MT_EVENT		BIT(7)
#define INSTRUCTION_MASK	GENMASK(5, 0)

enum ctn730_instruction {
	HOST_RESET = 0x00,
	HOST_CTRL_WRITE_PARAMETER = 0x01,
	HOST_CTRL_READ_PARAMETER = 0x02,
	HOST_CTRL_DL_OPEN_SESSION = 0x03,
	HOST_CTRL_DL_COMMIT_SESSION = 0x04,
	HOST_CTRL_DL_WRITE_FLASH = 0x05,
	HOST_CTRL_BIST = 0x06,
	HOST_CTRL_WRITE_SESSION_PARAMETER = 0x07,
	HOST_CTRL_READ_SESSION_PARAMETER = 0x08,
	HOST_CTRL_DUMP_STATUS = 0x0c,
	HOST_CTRL_GENERIC_ERROR = 0x0f,
	CHG_ENABLE = 0x10,
	CHG_DISABLE = 0x11,
	CHG_DEVICE_STATE = 0x12,
	CHG_CHARGING_STATE = 0x14,
	CHG_CHARGING_INFO = 0x15,
	CHG_OPTIONAL_NDEF = 0x1f,
	APP_CTRL_CHN_ENABLE = 0x20,
	APP_CTRL_CHN_DISABLE = 0x21,
	APP_CTRL_CHN_STATE = 0x22,
	APP_CTRL_CHN_SEND_DATA = 0x23,
	APP_CTRL_CHN_RECEIVE_DATA = 0x24,
};

enum ctn730_bist_id {
	BIST_RF_ON = 0x01,
	BIST_RF_OFF = 0x02,
	BIST_ACTIVATION = 0x04,
	BIST_READ_NTAG_BLOCKS = 0x09,
};

/* Host state machine. The order must match ctn730_status_text[]. */
enum ctn730_status {
	ST_UNKNOWN = 0,
	ST_DOWNLOAD_MODE,
	ST_INITIALIZED,
	ST_DETECTING,
	ST_DETECTED,
	ST_DEACTIVATED,
	ST_LOST,
	ST_VERSION_MISMATCH,
	ST_HOST_REQUEST_DISCHG,
	ST_RF_ON,
	ST_RF_OFF,
	ST_MAC_READ,
	ST_APP_CHN_ENABLED,
	ST_APP_CHN_DISABLED,
	ST_APP_CHN_CONNECTED,
	ST_APP_CHN_RECEIVED,
	ST_NEED_APP_CHN_ENABLE,
	ST_NEED_INFO_ENABLE,
	ST_NEED_INFO_DISABLE,
	ST_NEED_RF_ON,
	ST_NEED_RF_OFF,
	ST_DL_OPEN_OK,
	ST_DL_FLASH_OK,
	ST_DL_COMMIT_OK,
	ST_FW_UPDATE_ERR,
	ST_NEED_FW_DOWNLOAD,
	ST_BIST_ERR,
};

/* Strings (typos included) are the vendor ones: userspace may match them. */
static const char * const ctn730_status_text[] = {
	"status_unkown",
	"download_mode",
	"initialized",
	"detecting",
	"detected",
	"deactived",
	"lost",
	"version_missmatch",
	"host_request_dischg",
	"rf_on",
	"rf_off",
	"mac_getted",
	"app_chn_enabled",
	"app_chn_disabled",
	"app_chn_connected",
	"app_chn_reciced",
	"need_to_app_chmn_enable",
	"need_to_host_ctrl_enable_send_charging_info",
	"need_to_host_ctrl_disable_send_charging_info",
	"need_to_rf_on",
	"need_to_rf_off",
	"dl_open_session_ok",
	"dl_flash_ok",
	"dl_commit_ok",
	"update_firmware_err",
	"need_dowload_firmware",
	"bist_err",
};

enum ctn730_charge_state {
	CHARGE_UNKNOWN = 0,
	CHARGE_CHARGING,
	CHARGE_FULL,
	CHARGE_NOT_CHARGING,
};

static const char * const ctn730_charge_state_text[] = {
	"Unknown",
	"Charging",
	"Full",
	"Notcharging",
};

enum ctn730_ext_cmd {
	EXT_CMD_NONE = 0,
	EXT_CMD_RF_ON = 1,
	EXT_CMD_UPDATE_FIRMWARE = 2,
};

#define CTN730_MAX_PAYLOAD		255
#define CTN730_DETECT_INTERVAL_MS	500
#define CTN730_PEN_PARAM_LEN		32
#define CTN730_CMD_DELAY_MS		0
#define CTN730_MAC_DELAY_MS		50
#define CTN730_STATIC_CHECK_DELAY_MS	500
#define CTN730_DETECT_CHECK_DELAY_MS	2000
/*
 * Between detection pings the chip sleeps and NAKs its address; the first
 * access wakes it up and it answers some milliseconds later (the ChromeOS EC
 * driver for the same chip resends after 10 ms). Every command is specified
 * to complete within one second.
 */
#define CTN730_WAKE_DELAY_MS		10
#define CTN730_SEND_TRIES		3
#define CTN730_QUERY_TRIES		15
#define CTN730_MAX_SEND_FAILURES	30
#define CTN730_QUERY_TIMEOUT_MS		1000
#define CTN730_BOOT_TIMEOUT_MS		500
#define CTN730_BOOT_TRIES		5
#define CTN730_PARAM_COUNT		0x47
#define CTN730_STATUS_TAGS		8

#define CTN730_FW_BLOCK			128
#define CTN730_FW_USER_EE_ADDR		0x201200
#define CTN730_FW_USER_APP_ADDR		0x207000
#define CTN730_FW_USER_EE_MAX		3072
#define CTN730_FW_USER_EE_NAME		"user_ee_hostcontrolled.bin"
#define CTN730_FW_USER_APP_NAME		"wlc_host_user_app.bin"

static bool debug;
module_param(debug, bool, 0644);
MODULE_PARM_DESC(debug, "Log every frame exchanged with the chip");

static unsigned int detect_interval_ms = CTN730_DETECT_INTERVAL_MS;
module_param(detect_interval_ms, uint, 0644);
MODULE_PARM_DESC(detect_interval_ms, "Pen detection period passed to CHG_ENABLE (default: 500, takes effect at the next enable)");

static bool enable_on_probe = true;
module_param(enable_on_probe, bool, 0444);
MODULE_PARM_DESC(enable_on_probe, "Power the chip and start pen detection at probe (default: Y)");

static bool pen_power_supply = true;
module_param_named(power_supply, pen_power_supply, bool, 0444);
MODULE_PARM_DESC(power_supply, "Expose the docked pen as a power_supply device (default: Y)");

/*
 * DANGEROUS: lets the host rewrite the chip's user EEPROM/application flash.
 * Off by default; the update_firmware attribute does not exist without it.
 * This path is a straight port of vendor code that the vendor itself had
 * compiled out, and it has never been run on mainline.
 */
static bool allow_firmware_update;
module_param(allow_firmware_update, bool, 0444);
MODULE_PARM_DESC(allow_firmware_update, "Create the update_firmware attribute (UNTESTED, can brick the charger)");

/*
 * Bring-up fallback, only used when the I2C device has no firmware node
 * (instantiated through /sys/bus/i2c/devices/i2c-N/new_device).
 * Format: "<gpiochip label>,<line offset>".
 */
static bool suspend_ven_off;
module_param(suspend_ven_off, bool, 0644);
MODULE_PARM_DESC(suspend_ven_off, "Release CTN730 VEN during system suspend");

static char *enable_gpio;
module_param(enable_gpio, charp, 0444);
MODULE_PARM_DESC(enable_gpio, "Fallback VEN GPIO \"<chip label>,<offset>\" (active high)");

static char *reset_gpio;
module_param(reset_gpio, charp, 0444);
MODULE_PARM_DESC(reset_gpio, "Fallback reset GPIO \"<chip label>,<offset>\" (active low)");

static char *irq_gpio;
module_param(irq_gpio, charp, 0444);
MODULE_PARM_DESC(irq_gpio, "Fallback interrupt GPIO \"<chip label>,<offset>\" (active high)");

struct ctn730_pen {
	int level;		/* 0..100, -1 unknown */
	int attached;
	int charge_state;
	u8 mac[6];
	u8 uid[8];
};

struct ctn730_firmware {
	u8 *data;
	u32 user_ee_size;
	u32 size;
	u32 index;
	u32 crc;
	u8 version[2];
};

struct ctn730 {
	struct device *dev;
	struct i2c_client *client;
	struct miscdevice misc;
	bool misc_registered;

	struct gpio_desc *enable_gpiod;
	struct gpio_desc *reset_gpiod;
	int irq;

	struct mutex power_lock;	/* serializes enable/disable */
	struct mutex lock;		/* protects everything below */

	struct ctn730_pen pen;
	struct ctn730_firmware fw;

	int status;
	int ext_cmd;
	int bist_id;
	int report_info_id;
	int app_data_ok;
	unsigned int send_failures;
	bool enabled;
	bool suspend_ven_released;
	bool suspend_irq_masked;
	bool removing;
	bool have_mac;
	bool host_ctrl_flag;
	bool initialized;
	bool report_info;
	bool need_report_info;
	bool static_check_armed;
	u8 version[2];
	u8 pen_param[CTN730_PEN_PARAM_LEN];
	u8 pen_param_count;
	u8 bist_result[CTN730_MAX_PAYLOAD];
	u8 bist_result_len;

	/* Synchronous diagnostic queries (sysfs) */
	struct mutex query_lock;
	struct completion query_done;
	bool query_pending;
	u8 query_ins;
	u8 query_resp[CTN730_MAX_PAYLOAD];
	u8 query_len;

	u8 tx[2 + CTN730_MAX_PAYLOAD];
	u8 rx_hdr[2];
	u8 rx[CTN730_MAX_PAYLOAD + 1];

	struct delayed_work set_work;
	struct delayed_work rf_on_work;
	struct delayed_work update_firmware_work;
	struct delayed_work check_static_charge_work;
	struct delayed_work boot_work;
	unsigned int boot_tries;

	struct work_struct psy_work;
	struct power_supply *psy;
};

#define ctn730_frame_dbg(ctn, dir, hdr, payload, len)			\
do {									\
	if (debug)							\
		dev_info((ctn)->dev, dir " %2ph %*ph%s\n", hdr,		\
			 (int)min_t(size_t, len, 64), payload,		\
			 (len) > 64 ? " ..." : "");			\
} while (0)

/* -------------------------------------------------------------------------
 * Notifications
 */

static void ctn730_notify(struct ctn730 *ctn)
{
	lockdep_assert_held(&ctn->lock);

	if (ctn->removing || !ctn->misc_registered)
		return;

	kobject_uevent(&ctn->misc.this_device->kobj, KOBJ_CHANGE);
	ctn->app_data_ok = 0;
	if (pen_power_supply)
		schedule_work(&ctn->psy_work);
}

static void ctn730_clear_pen(struct ctn730 *ctn)
{
	ctn->pen.attached = 0;
	ctn->pen.level = -1;
	ctn->pen.charge_state = CHARGE_UNKNOWN;
	ctn->have_mac = false;
	memset(ctn->pen.mac, 0, sizeof(ctn->pen.mac));
	memset(ctn->pen.uid, 0, sizeof(ctn->pen.uid));
}

static void ctn730_set_status(struct ctn730 *ctn, int status)
{
	ctn->status = status;
	dev_dbg(ctn->dev, "status %s\n", ctn730_status_text[status]);
}

/* Re-run whichever state machine currently owns the chip. */
static void ctn730_kick(struct ctn730 *ctn, unsigned int delay_ms)
{
	struct delayed_work *work;

	if (!ctn->enabled)
		return;

	switch (ctn->ext_cmd) {
	case EXT_CMD_RF_ON:
		work = &ctn->rf_on_work;
		break;
	case EXT_CMD_UPDATE_FIRMWARE:
		work = &ctn->update_firmware_work;
		break;
	default:
		work = &ctn->set_work;
		break;
	}
	schedule_delayed_work(work, msecs_to_jiffies(delay_ms));
}

static void ctn730_arm_static_check(struct ctn730 *ctn, unsigned int delay_ms)
{
	ctn->static_check_armed = true;
	mod_delayed_work(system_wq, &ctn->check_static_charge_work,
			 msecs_to_jiffies(delay_ms));
}

static void ctn730_disarm_static_check(struct ctn730 *ctn)
{
	ctn->static_check_armed = false;
	cancel_delayed_work(&ctn->check_static_charge_work);
}

/* -------------------------------------------------------------------------
 * Commands
 */

static void ctn730_hard_reset(struct ctn730 *ctn);

/* One command frame, resent while the chip is waking up (address NAK). */
static int ctn730_xfer(struct ctn730 *ctn, u8 ins, const u8 *payload, u8 len,
		       unsigned int tries)
{
	int count = len + 2;
	int ret;

	lockdep_assert_held(&ctn->lock);

	if (!ctn->enabled)
		return -ESHUTDOWN;

	ctn->tx[0] = ins;
	ctn->tx[1] = len;
	if (len)
		memcpy(&ctn->tx[2], payload, len);

	ctn730_frame_dbg(ctn, "tx", ctn->tx, &ctn->tx[2], len);

	for (;;) {
		ret = i2c_master_send(ctn->client, ctn->tx, count);
		if (ret == count)
			return 0;
		if (ret >= 0)
			ret = -EIO;
		if (!--tries)
			return ret;
		msleep(CTN730_WAKE_DELAY_MS);
	}
}

static int ctn730_send(struct ctn730 *ctn, u8 ins, const u8 *payload, u8 len)
{
	int ret;

	ret = ctn730_xfer(ctn, ins, payload, len, CTN730_SEND_TRIES);
	if (!ret) {
		ctn->send_failures = 0;
		return 0;
	}
	if (ret == -ESHUTDOWN)
		return ret;

	if (++ctn->send_failures > CTN730_MAX_SEND_FAILURES) {
		dev_err(ctn->dev, "command %#04x not accepted after %u attempts (%d)\n",
			ins, ctn->send_failures * CTN730_SEND_TRIES, ret);
		ctn->send_failures = 0;
		/*
		 * The host state no longer matches the chip. Restart the chip
		 * so that both begin again from the reset event, unless the
		 * reset command itself is what failed.
		 */
		if (ins != HOST_RESET && ctn->ext_cmd != EXT_CMD_UPDATE_FIRMWARE)
			ctn730_hard_reset(ctn);
		return -EIO;
	}

	dev_dbg(ctn->dev, "command %#04x failed (%d), retrying\n", ins, ret);
	ctn730_kick(ctn, CTN730_WAKE_DELAY_MS);
	return -EIO;
}

/*
 * Send a command and wait for its response. For diagnostics from sysfs only:
 * the response does not go through the state machine. Returns the payload
 * length (status byte first) or a negative error.
 */
static int ctn730_query(struct ctn730 *ctn, u8 ins, const u8 *payload, u8 len,
			u8 *resp, size_t size)
{
	int ret;

	guard(mutex)(&ctn->query_lock);

	scoped_guard(mutex, &ctn->lock) {
		reinit_completion(&ctn->query_done);
		ctn->query_ins = ins;
		ctn->query_pending = true;
		ret = ctn730_xfer(ctn, ins, payload, len, CTN730_QUERY_TRIES);
		if (ret) {
			ctn->query_pending = false;
			return ret;
		}
	}

	ret = wait_for_completion_timeout(&ctn->query_done,
					  msecs_to_jiffies(CTN730_QUERY_TIMEOUT_MS));

	guard(mutex)(&ctn->lock);
	ctn->query_pending = false;
	if (!ret)
		return -ETIMEDOUT;

	ret = min_t(size_t, ctn->query_len, size);
	memcpy(resp, ctn->query_resp, ret);
	return ret;
}

static void ctn730_hard_reset(struct ctn730 *ctn)
{
	if (!ctn->reset_gpiod) {
		dev_warn(ctn->dev, "no reset GPIO, cannot hard reset\n");
		return;
	}

	dev_dbg(ctn->dev, "hard reset\n");
	gpiod_set_value_cansleep(ctn->reset_gpiod, 1);
	msleep(5);
	gpiod_set_value_cansleep(ctn->reset_gpiod, 0);
	ctn->initialized = false;
}

/* Leave download mode and start the user application. */
static void ctn730_reset_init(struct ctn730 *ctn)
{
	static const u8 p[] = { 0x00 };

	if (!ctn730_send(ctn, HOST_RESET, p, sizeof(p)))
		ctn->initialized = true;
}

static void ctn730_enable_chg(struct ctn730 *ctn)
{
	u8 p[2];

	put_unaligned_le16(clamp(detect_interval_ms, 1U, 0xffffU), p);
	ctn730_send(ctn, CHG_ENABLE, p, sizeof(p));
}

static void ctn730_disable_chg(struct ctn730 *ctn)
{
	ctn730_send(ctn, CHG_DISABLE, NULL, 0);
}

static int ctn730_bist(struct ctn730 *ctn, const u8 *p, u8 len)
{
	int ret;

	ret = ctn730_send(ctn, HOST_CTRL_BIST, p, len);
	if (!ret)
		ctn->bist_id = p[0];
	return ret;
}

static int ctn730_rf_on(struct ctn730 *ctn)
{
	static const u8 p[] = { BIST_RF_ON };

	return ctn730_bist(ctn, p, sizeof(p));
}

static int ctn730_rf_off(struct ctn730 *ctn)
{
	static const u8 p[] = { BIST_RF_OFF };

	return ctn730_bist(ctn, p, sizeof(p));
}

/* Read NTAG block 0x10 of the pen: it holds the pen's Bluetooth address. */
static int ctn730_get_mac(struct ctn730 *ctn)
{
	static const u8 p[] = { BIST_READ_NTAG_BLOCKS, 0x10, 0x01 };

	return ctn730_bist(ctn, p, sizeof(p));
}

static int ctn730_cn_test(struct ctn730 *ctn)
{
	static const u8 p[] = { BIST_ACTIVATION };

	return ctn730_bist(ctn, p, sizeof(p));
}

static void ctn730_enable_app_channel(struct ctn730 *ctn)
{
	ctn730_send(ctn, APP_CTRL_CHN_ENABLE, NULL, 0);
}

static void ctn730_disable_app_channel(struct ctn730 *ctn)
{
	ctn730_send(ctn, APP_CTRL_CHN_DISABLE, NULL, 0);
}

static void ctn730_set_charging_info(struct ctn730 *ctn, bool on)
{
	u8 p[2] = { 0x00, on };

	if (!ctn730_send(ctn, HOST_CTRL_WRITE_SESSION_PARAMETER, p, sizeof(p)))
		ctn->report_info_id = on;
}

static void ctn730_app_set_param(struct ctn730 *ctn)
{
	u8 p[1 + CTN730_PEN_PARAM_LEN];

	p[0] = 0x01;
	memcpy(&p[1], ctn->pen_param, ctn->pen_param_count);
	ctn730_send(ctn, APP_CTRL_CHN_SEND_DATA, p, 1 + ctn->pen_param_count);
}

/* -------------------------------------------------------------------------
 * Firmware download (only reachable with allow_firmware_update=1)
 */

static int ctn730_dl_open(struct ctn730 *ctn)
{
	return ctn730_send(ctn, HOST_CTRL_DL_OPEN_SESSION, ctn->fw.version,
			   sizeof(ctn->fw.version));
}

static int ctn730_dl_commit(struct ctn730 *ctn, u32 crc)
{
	u8 p[4];

	put_unaligned_le32(crc, p);
	return ctn730_send(ctn, HOST_CTRL_DL_COMMIT_SESSION, p, sizeof(p));
}

static int ctn730_dl_flash(struct ctn730 *ctn, const u8 *data, u32 addr)
{
	u8 p[3 + CTN730_FW_BLOCK];

	put_unaligned_le24(addr, p);
	memcpy(&p[3], data, CTN730_FW_BLOCK);
	return ctn730_send(ctn, HOST_CTRL_DL_WRITE_FLASH, p, sizeof(p));
}

static void ctn730_fw_free(struct ctn730 *ctn)
{
	kvfree(ctn->fw.data);
	ctn->fw.data = NULL;
	ctn->fw.size = 0;
	ctn->fw.index = 0;
}

/* -------------------------------------------------------------------------
 * Message parser
 */

static void ctn730_parse_event(struct ctn730 *ctn, u8 ins, const u8 *data, int count)
{
	int charge_state, level;

	switch (ins) {
	case HOST_RESET:
		if (data[0] == 0 && count >= 3) {
			ctn730_set_status(ctn, ST_INITIALIZED);
			ctn->version[0] = data[1];
			ctn->version[1] = data[2];
			ctn730_clear_pen(ctn);
			ctn730_notify(ctn);
			dev_info(ctn->dev, "firmware version %02x%02x\n",
				 ctn->version[0], ctn->version[1]);
		} else if (data[0] == 1) {
			ctn730_set_status(ctn, ST_DOWNLOAD_MODE);
			if (ctn->initialized) {
				/* It refused to start the user application. */
				ctn730_set_status(ctn, ST_NEED_FW_DOWNLOAD);
				dev_err(ctn->dev, "chip stays in download mode: no valid user firmware\n");
			}
		}
		ctn730_kick(ctn, CTN730_CMD_DELAY_MS);
		break;

	case CHG_DEVICE_STATE:
		switch (data[0]) {
		case 0:
			ctn730_set_status(ctn, ST_DETECTED);
			ctn730_disarm_static_check(ctn);
			ctn->pen.attached = 1;
			memset(ctn->pen.uid, 0, sizeof(ctn->pen.uid));
			memcpy(ctn->pen.uid, data + 1, min(count - 1, 7));
			dev_dbg(ctn->dev, "pen detected, uid %7ph\n", ctn->pen.uid);
			ctn730_kick(ctn, CTN730_CMD_DELAY_MS);
			ctn730_notify(ctn);
			break;
		case 1:
			ctn730_set_status(ctn, ST_DEACTIVATED);
			break;
		case 2:
			ctn730_set_status(ctn, ST_LOST);
			ctn730_clear_pen(ctn);
			ctn730_notify(ctn);
			break;
		case 3:
			ctn730_set_status(ctn, ST_VERSION_MISMATCH);
			dev_warn(ctn->dev, "pen speaks an unsupported WLC protocol version\n");
			break;
		case 4:
		case 5:
			/*
			 * 4 "docked" / 5 "undocked": a listener is in the field
			 * and is being statically charged, but there is no
			 * digital (negotiated) session yet. The chip repeats
			 * the event; consider the pen gone when it stops.
			 */
			dev_dbg(ctn->dev, "pen %s\n", data[0] == 4 ? "docked" : "undocked");
			if (!ctn->pen.attached) {
				ctn->pen.attached = 1;
				ctn730_notify(ctn);
			}
			ctn730_arm_static_check(ctn, CTN730_STATIC_CHECK_DELAY_MS);
			break;
		/* Not handled by the vendor driver; names from the ChromeOS EC. */
		case 6:
			dev_warn_ratelimited(ctn->dev, "foreign object on the pen charger\n");
			break;
		case 7:
			dev_info(ctn->dev, "pen reports battery full\n");
			break;
		case 8:
			dev_warn_ratelimited(ctn->dev, "pen charge failure\n");
			break;
		case 0x0a:
			dev_info(ctn->dev, "listener is a plain NDEF tag, not a pen\n");
			break;
		case 0xfa:
			dev_warn_ratelimited(ctn->dev, "pen over temperature\n");
			break;
		default:
			dev_info(ctn->dev, "unknown device state %#04x\n", data[0]);
			break;
		}
		break;

	case CHG_CHARGING_STATE:
		charge_state = ctn->pen.charge_state;
		switch (data[0]) {
		case 0:
			charge_state = CHARGE_CHARGING;
			if (ctn->need_report_info && !ctn->report_info && ctn->have_mac) {
				ctn730_set_status(ctn, ST_NEED_INFO_ENABLE);
				schedule_delayed_work(&ctn->set_work,
						      msecs_to_jiffies(CTN730_CMD_DELAY_MS));
			}
			break;
		case 1:
			charge_state = CHARGE_FULL;
			break;
		case 2:
			/* Charging stops while the host reads the MAC. */
			if (!ctn->host_ctrl_flag)
				charge_state = CHARGE_NOT_CHARGING;
			break;
		}
		if (charge_state != ctn->pen.charge_state) {
			ctn->pen.charge_state = charge_state;
			dev_dbg(ctn->dev, "charge state %s\n",
				ctn730_charge_state_text[charge_state]);
			ctn730_notify(ctn);
		}
		break;

	case CHG_CHARGING_INFO:
		level = data[0] == 0xff ? -1 : data[0];
		if (level != ctn->pen.level) {
			ctn->pen.level = level;
			dev_dbg(ctn->dev, "pen battery level %d\n", level);
			ctn730_notify(ctn);
		}
		break;

	case CHG_DISABLE:
		if (data[0] == 0) {
			ctn730_set_status(ctn, ST_HOST_REQUEST_DISCHG);
			schedule_delayed_work(&ctn->set_work,
					      msecs_to_jiffies(CTN730_MAC_DELAY_MS));
		} else if (data[0] == 1) {
			dev_warn(ctn->dev, "charging disabled by the chip: over temperature\n");
		}
		break;

	case APP_CTRL_CHN_STATE:
		if (data[0] == 0) {
			ctn730_set_status(ctn, ST_APP_CHN_CONNECTED);
			schedule_delayed_work(&ctn->set_work,
					      msecs_to_jiffies(CTN730_CMD_DELAY_MS));
		} else if (data[0] == 1) {
			/* application channel disconnected */
			ctn730_set_status(ctn, ST_DETECTED);
		}
		break;

	case APP_CTRL_CHN_SEND_DATA:
		break;

	case APP_CTRL_CHN_RECEIVE_DATA:
		if (data[0] == 1) {
			/* last chunk; the pen echoes the pen_cmd pattern */
			ctn730_set_status(ctn, ST_APP_CHN_RECEIVED);
			schedule_delayed_work(&ctn->set_work,
					      msecs_to_jiffies(CTN730_CMD_DELAY_MS));
			if (count >= 5 && data[1] == 0xaa && data[2] == 0x55 &&
			    data[3] == 0xcc && data[4] == 0x33)
				ctn->app_data_ok = 2;
			else
				ctn->app_data_ok = 1;
			ctn730_notify(ctn);
		}
		break;

	case HOST_CTRL_GENERIC_ERROR:
		dev_warn(ctn->dev, "chip reports an error: %*ph\n", min(count, 64), data);
		break;

	case CHG_OPTIONAL_NDEF:
		dev_dbg(ctn->dev, "optional NDEF from the pen: %*ph\n",
			min(count, 64), data);
		break;

	default:
		dev_info(ctn->dev, "unhandled event %#04x: %*ph\n", ins,
			 min(count, 64), data);
		break;
	}
}

static void ctn730_parse_response(struct ctn730 *ctn, u8 ins, const u8 *data, int count)
{
	bool ok = data[0] == STATUS_OK;

	switch (ins) {
	case CHG_ENABLE:
		if (ok) {
			ctn730_set_status(ctn, ST_DETECTING);
			ctn730_arm_static_check(ctn, CTN730_DETECT_CHECK_DELAY_MS);
		} else {
			dev_err(ctn->dev, "CHG_ENABLE failed: %#04x\n", data[0]);
		}
		break;

	case CHG_DISABLE:
		if (!ok)
			dev_err(ctn->dev, "CHG_DISABLE failed: %#04x\n", data[0]);
		break;

	case HOST_CTRL_BIST:
		ctn->bist_result_len = count;
		memcpy(ctn->bist_result, data, count);

		if (!ok) {
			dev_dbg(ctn->dev, "BIST %#04x failed: %#04x\n",
				ctn->bist_id, data[0]);
			ctn730_set_status(ctn, ST_BIST_ERR);
			schedule_delayed_work(&ctn->set_work,
					      msecs_to_jiffies(CTN730_CMD_DELAY_MS));
			break;
		}

		switch (ctn->bist_id) {
		case BIST_RF_ON:
			ctn730_set_status(ctn, ST_RF_ON);
			break;
		case BIST_RF_OFF:
			ctn730_set_status(ctn, ST_RF_OFF);
			break;
		case BIST_READ_NTAG_BLOCKS:
			if (count < 7)
				break;
			memcpy(ctn->pen.mac, data + 1, sizeof(ctn->pen.mac));
			ctn730_set_status(ctn, ST_MAC_READ);
			ctn->have_mac = true;
			ctn730_notify(ctn);
			break;
		}
		if (ctn->ext_cmd == EXT_CMD_NONE)
			schedule_delayed_work(&ctn->set_work,
					      msecs_to_jiffies(CTN730_CMD_DELAY_MS));
		break;

	case APP_CTRL_CHN_ENABLE:
		if (ok)
			ctn730_set_status(ctn, ST_APP_CHN_ENABLED);
		break;

	case APP_CTRL_CHN_SEND_DATA:
		if (ok) {
			ctn730_set_status(ctn, ST_DETECTED);
		} else {
			ctn->app_data_ok = 1;
			ctn730_notify(ctn);
		}
		break;

	case APP_CTRL_CHN_DISABLE:
		if (ok)
			ctn730_set_status(ctn, ST_APP_CHN_DISABLED);
		break;

	case HOST_CTRL_WRITE_SESSION_PARAMETER:
		if (ok) {
			ctn730_set_status(ctn, ST_DETECTED);
			ctn->report_info = ctn->report_info_id;
		} else {
			dev_err(ctn->dev, "WRITE_SESSION_PARAMETER failed: %#04x\n", data[0]);
		}
		break;

	case HOST_CTRL_DL_OPEN_SESSION:
	case HOST_CTRL_DL_COMMIT_SESSION:
	case HOST_CTRL_DL_WRITE_FLASH:
		if (!ok) {
			dev_err(ctn->dev, "download command %#04x failed: %#04x\n",
				ins, data[0]);
			ctn730_set_status(ctn, ST_FW_UPDATE_ERR);
		} else if (ins == HOST_CTRL_DL_OPEN_SESSION) {
			ctn730_set_status(ctn, ST_DL_OPEN_OK);
		} else if (ins == HOST_CTRL_DL_COMMIT_SESSION) {
			ctn730_set_status(ctn, ST_DL_COMMIT_OK);
		} else {
			ctn730_set_status(ctn, ST_DL_FLASH_OK);
		}
		ctn730_kick(ctn, CTN730_CMD_DELAY_MS);
		break;

	default:
		dev_dbg(ctn->dev, "unhandled response %#04x: %*ph\n", ins,
			min(count, 64), data);
		break;
	}
}

static void ctn730_parse_message(struct ctn730 *ctn, u8 hdr, const u8 *data, int count)
{
	u8 ins = hdr & INSTRUCTION_MASK;

	lockdep_assert_held(&ctn->lock);

	if (ctn->query_pending && hdr == (MT_RESPONSE | ctn->query_ins)) {
		ctn->query_len = count;
		memcpy(ctn->query_resp, data, count);
		ctn->query_pending = false;
		complete(&ctn->query_done);
		return;
	}

	/* Every known response and event carries at least one byte. */
	if (count < 1)
		return;

	switch (hdr & MT_MASK) {
	case MT_EVENT:
		ctn730_parse_event(ctn, ins, data, count);
		break;
	case MT_RESPONSE:
		ctn730_parse_response(ctn, ins, data, count);
		break;
	default:
		break;
	}
}

static irqreturn_t ctn730_irq_thread(int irq, void *dev_id)
{
	struct ctn730 *ctn = dev_id;
	int len, ret, tries;

	/*
	 * The chip returns the 2-byte header and the payload in two reads.
	 * It can raise the line and still NAK its address while it wakes up
	 * (seen right after CHG_ENABLE): read again before giving up, as the
	 * ChromeOS EC driver does. If the line is still high after that, the
	 * level interrupt simply fires again.
	 */
	for (tries = 3; ; ) {
		ret = i2c_master_recv(ctn->client, ctn->rx_hdr, sizeof(ctn->rx_hdr));
		if (ret == sizeof(ctn->rx_hdr))
			break;
		if (!--tries) {
			if (ret == -ENXIO)
				dev_dbg(ctn->dev, "interrupt without data (NAK)\n");
			else
				dev_err_ratelimited(ctn->dev, "header read failed: %d\n", ret);
			return IRQ_HANDLED;
		}
		msleep(CTN730_WAKE_DELAY_MS);
	}

	len = ctn->rx_hdr[1];
	memset(ctn->rx, 0, sizeof(ctn->rx));
	if (len) {
		ret = i2c_master_recv(ctn->client, ctn->rx, len);
		if (ret != len) {
			dev_err_ratelimited(ctn->dev, "payload read failed: %d\n", ret);
			msleep(20);
			return IRQ_HANDLED;
		}
	}

	ctn730_frame_dbg(ctn, "rx", ctn->rx_hdr, ctn->rx, len);

	mutex_lock(&ctn->lock);
	if (ctn->enabled)
		ctn730_parse_message(ctn, ctn->rx_hdr[0], ctn->rx, len);
	mutex_unlock(&ctn->lock);

	/* Give the chip time to release the (level triggered) IRQ line. */
	usleep_range(5000, 6000);
	return IRQ_HANDLED;
}

/* -------------------------------------------------------------------------
 * State machines
 */

static void ctn730_set_work(struct work_struct *work)
{
	struct ctn730 *ctn = container_of(work, struct ctn730, set_work.work);

	guard(mutex)(&ctn->lock);

	if (ctn->ext_cmd != EXT_CMD_NONE)
		return;

	switch (ctn->status) {
	case ST_DOWNLOAD_MODE:
	case ST_BIST_ERR:
		ctn730_reset_init(ctn);
		break;
	case ST_INITIALIZED:
		ctn730_enable_chg(ctn);
		break;
	case ST_DETECTED:
		/* Stop charging to read the pen's Bluetooth address once. */
		if (!ctn->have_mac) {
			ctn730_disable_chg(ctn);
			ctn->host_ctrl_flag = true;
		}
		break;
	case ST_HOST_REQUEST_DISCHG:
		ctn730_rf_on(ctn);
		break;
	case ST_RF_ON:
		if (!ctn->have_mac)
			ctn730_get_mac(ctn);
		break;
	case ST_MAC_READ:
		ctn730_rf_off(ctn);
		break;
	case ST_RF_OFF:
		ctn730_enable_chg(ctn);
		ctn->host_ctrl_flag = false;
		break;
	case ST_NEED_APP_CHN_ENABLE:
		ctn730_enable_app_channel(ctn);
		break;
	case ST_APP_CHN_CONNECTED:
		ctn730_app_set_param(ctn);
		break;
	case ST_APP_CHN_RECEIVED:
		ctn730_disable_app_channel(ctn);
		break;
	case ST_NEED_INFO_ENABLE:
		ctn730_set_charging_info(ctn, true);
		break;
	case ST_NEED_INFO_DISABLE:
		ctn730_set_charging_info(ctn, false);
		break;
	case ST_NEED_RF_ON:
		ctn730_disable_chg(ctn);
		break;
	case ST_NEED_RF_OFF:
		ctn730_rf_off(ctn);
		break;
	default:
		break;
	}
}

static void ctn730_check_static_charge_work(struct work_struct *work)
{
	struct ctn730 *ctn = container_of(work, struct ctn730,
					  check_static_charge_work.work);

	guard(mutex)(&ctn->lock);

	if (!ctn->static_check_armed)
		return;
	ctn->static_check_armed = false;

	if (!ctn->pen.attached && ctn->pen.level == -1 &&
	    ctn->pen.charge_state == CHARGE_UNKNOWN && !ctn->have_mac)
		return;

	ctn730_clear_pen(ctn);
	ctn730_notify(ctn);
}

/*
 * The chip announces itself with a HOST_RESET event after VEN goes high. If
 * VEN was low only briefly the event sometimes never comes and the state
 * machine would wait forever: pulse the reset line until it does.
 */
static void ctn730_boot_work(struct work_struct *work)
{
	struct ctn730 *ctn = container_of(work, struct ctn730, boot_work.work);

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled || ctn->status != ST_UNKNOWN)
		return;

	if (++ctn->boot_tries > CTN730_BOOT_TRIES) {
		dev_err(ctn->dev, "chip does not start\n");
		return;
	}

	dev_warn(ctn->dev, "no reset event from the chip, resetting it (%u)\n",
		 ctn->boot_tries);
	ctn730_hard_reset(ctn);
	schedule_delayed_work(&ctn->boot_work,
			      msecs_to_jiffies(CTN730_BOOT_TIMEOUT_MS));
}

/* Factory test mode: keep the RF field on continuously (no charging). */
static void ctn730_rf_on_work(struct work_struct *work)
{
	struct ctn730 *ctn = container_of(work, struct ctn730, rf_on_work.work);

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled)
		return;

	if (ctn->ext_cmd == EXT_CMD_NONE) {
		/* Leaving test mode: restart the chip into normal operation. */
		ctn730_hard_reset(ctn);
		return;
	}
	if (ctn->ext_cmd != EXT_CMD_RF_ON)
		return;

	switch (ctn->status) {
	case ST_DOWNLOAD_MODE:
		ctn730_reset_init(ctn);
		break;
	case ST_INITIALIZED:
		ctn730_rf_on(ctn);
		break;
	default:
		ctn730_hard_reset(ctn);
		break;
	}
}

static void ctn730_update_firmware_work(struct work_struct *work)
{
	struct ctn730 *ctn = container_of(work, struct ctn730,
					  update_firmware_work.work);
	struct ctn730_firmware *fw = &ctn->fw;
	u32 ee_blocks, blocks, addr;

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled || ctn->ext_cmd != EXT_CMD_UPDATE_FIRMWARE || !fw->data)
		return;

	ee_blocks = fw->user_ee_size / CTN730_FW_BLOCK;
	blocks = fw->size / CTN730_FW_BLOCK;

	switch (ctn->status) {
	case ST_DOWNLOAD_MODE:
		ctn730_dl_open(ctn);
		break;

	case ST_DL_OPEN_OK:
	case ST_DL_FLASH_OK:
		if (fw->index < blocks) {
			if (fw->index < ee_blocks)
				addr = CTN730_FW_USER_EE_ADDR +
				       fw->index * CTN730_FW_BLOCK;
			else
				addr = CTN730_FW_USER_APP_ADDR +
				       (fw->index - ee_blocks) * CTN730_FW_BLOCK;
			if (!ctn730_dl_flash(ctn, fw->data + fw->index * CTN730_FW_BLOCK, addr))
				fw->index++;
		} else if (fw->index == blocks) {
			if (!ctn730_dl_commit(ctn, fw->crc))
				fw->index++;
		}
		break;

	case ST_DL_COMMIT_OK:
		dev_info(ctn->dev, "firmware download committed\n");
		ctn->ext_cmd = EXT_CMD_NONE;
		ctn730_set_status(ctn, ST_DOWNLOAD_MODE);
		ctn730_fw_free(ctn);
		schedule_delayed_work(&ctn->set_work, msecs_to_jiffies(100));
		break;

	default:
		dev_err(ctn->dev, "firmware download aborted in state %s\n",
			ctn730_status_text[ctn->status]);
		ctn->ext_cmd = EXT_CMD_NONE;
		ctn730_fw_free(ctn);
		ctn730_hard_reset(ctn);
		break;
	}
}

/* -------------------------------------------------------------------------
 * Power control
 */

static int ctn730_enable_locked(struct ctn730 *ctn)
{
	lockdep_assert_held(&ctn->power_lock);

	scoped_guard(mutex, &ctn->lock) {
		if (ctn->removing)
			return -ENODEV;
		if (ctn->enabled)
			return 0;

		ctn->status = ST_UNKNOWN;
		ctn->send_failures = 0;
		ctn->initialized = false;
		ctn->enabled = true;
		ctn->boot_tries = 0;
		gpiod_set_value_cansleep(ctn->reset_gpiod, 0);
		gpiod_set_value_cansleep(ctn->enable_gpiod, 1);
	}

	/* The chip announces itself with a HOST_RESET event. */
	enable_irq(ctn->irq);
	schedule_delayed_work(&ctn->boot_work,
			      msecs_to_jiffies(CTN730_BOOT_TIMEOUT_MS));
	return 0;
}

static int ctn730_enable(struct ctn730 *ctn)
{
	guard(mutex)(&ctn->power_lock);

	if (ctn->suspend_ven_released || ctn->suspend_irq_masked)
		return -EBUSY;
	return ctn730_enable_locked(ctn);
}

static bool ctn730_disable_locked(struct ctn730 *ctn, bool idle_only)
{
	lockdep_assert_held(&ctn->power_lock);

	scoped_guard(mutex, &ctn->lock) {
		if (!ctn->enabled)
			return false;
		if (idle_only && (!ctn->initialized || ctn->pen.attached ||
				  ctn->ext_cmd != EXT_CMD_NONE ||
				  (ctn->status != ST_DETECTING && ctn->status != ST_LOST)))
			return false;
		ctn->enabled = false;
		ctn->ext_cmd = EXT_CMD_NONE;
	}

	/* Not under ctn->lock: these wait for code that takes it. */
	if (!ctn->suspend_irq_masked)
		disable_irq(ctn->irq);
	ctn->suspend_irq_masked = false;
	cancel_delayed_work_sync(&ctn->boot_work);
	cancel_delayed_work_sync(&ctn->set_work);
	cancel_delayed_work_sync(&ctn->rf_on_work);
	cancel_delayed_work_sync(&ctn->update_firmware_work);
	cancel_delayed_work_sync(&ctn->check_static_charge_work);

	scoped_guard(mutex, &ctn->lock) {
		gpiod_set_value_cansleep(ctn->enable_gpiod, 0);
		ctn->initialized = false;
		ctn->static_check_armed = false;
		ctn->status = ST_UNKNOWN;
		ctn730_fw_free(ctn);
		ctn730_clear_pen(ctn);
		ctn730_notify(ctn);
	}

	return true;
}

static void ctn730_disable(struct ctn730 *ctn)
{
	guard(mutex)(&ctn->power_lock);

	ctn->suspend_ven_released = false;
	ctn730_disable_locked(ctn, false);
}

/* -------------------------------------------------------------------------
 * Pen battery (power_supply)
 */

static const enum power_supply_property ctn730_psy_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_SCOPE,
	POWER_SUPPLY_PROP_MODEL_NAME,
};

static int ctn730_psy_get_property(struct power_supply *psy,
				   enum power_supply_property psp,
				   union power_supply_propval *val)
{
	struct ctn730 *ctn = power_supply_get_drvdata(psy);
	int level;

	/* Lockless on purpose: the supply is unregistered from a work item. */
	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		switch (READ_ONCE(ctn->pen.charge_state)) {
		case CHARGE_CHARGING:
			val->intval = POWER_SUPPLY_STATUS_CHARGING;
			break;
		case CHARGE_FULL:
			val->intval = POWER_SUPPLY_STATUS_FULL;
			break;
		case CHARGE_NOT_CHARGING:
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
			break;
		default:
			val->intval = POWER_SUPPLY_STATUS_UNKNOWN;
			break;
		}
		return 0;
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = READ_ONCE(ctn->pen.attached);
		return 0;
	case POWER_SUPPLY_PROP_CAPACITY:
		level = READ_ONCE(ctn->pen.level);
		if (level < 0)
			return -ENODATA;
		val->intval = min(level, 100);
		return 0;
	case POWER_SUPPLY_PROP_SCOPE:
		val->intval = POWER_SUPPLY_SCOPE_DEVICE;
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "NFC charged stylus";
		return 0;
	default:
		return -EINVAL;
	}
}

static const struct power_supply_desc ctn730_psy_desc = {
	.name = "ctn730-pen",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = ctn730_psy_props,
	.num_properties = ARRAY_SIZE(ctn730_psy_props),
	.get_property = ctn730_psy_get_property,
};

/* The supply only exists while a pen sits on the charger. */
static void ctn730_psy_work(struct work_struct *work)
{
	struct ctn730 *ctn = container_of(work, struct ctn730, psy_work);
	struct power_supply_config cfg = { .drv_data = ctn };
	bool attached = READ_ONCE(ctn->pen.attached);

	if (attached && !ctn->psy) {
		ctn->psy = power_supply_register(ctn->dev, &ctn730_psy_desc, &cfg);
		if (IS_ERR(ctn->psy)) {
			dev_warn(ctn->dev, "cannot register pen power supply: %pe\n",
				 ctn->psy);
			ctn->psy = NULL;
		}
	} else if (!attached && ctn->psy) {
		power_supply_unregister(ctn->psy);
		ctn->psy = NULL;
	} else if (ctn->psy) {
		power_supply_changed(ctn->psy);
	}
}

/* -------------------------------------------------------------------------
 * sysfs (on the misc device, same names as the vendor driver)
 */

static struct ctn730 *dev_to_ctn730(const struct device *dev)
{
	struct miscdevice *misc = dev_get_drvdata(dev);

	return container_of(misc, struct ctn730, misc);
}

static ssize_t enable_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	bool enable;
	int ret;

	ret = kstrtobool(buf, &enable);
	if (ret)
		return ret;

	if (enable)
		ret = ctn730_enable(ctn);
	else
		ctn730_disable(ctn);

	return ret ?: size;
}

static ssize_t enable_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	return sysfs_emit(buf, "%d\n", READ_ONCE(ctn->enabled));
}

/*
 * Sends the pattern aa 55 cc 33 to the pen over the NFC application channel.
 * On the stock system this is issued when the Bluetooth pairing of the pen
 * is cleared ("sys.lenovobt.pen_pairing"): expect the pen to forget its bond.
 */
static ssize_t pen_cmd_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t size)
{
	static const u8 pattern[] = { 0xaa, 0x55, 0xcc, 0x33 };
	struct ctn730 *ctn = dev_to_ctn730(dev);
	bool go;
	int ret;

	ret = kstrtobool(buf, &go);
	if (ret)
		return ret;
	if (!go)
		return size;

	guard(mutex)(&ctn->lock);

	if (ctn->status != ST_DETECTED || !ctn->have_mac)
		return -EBUSY;

	memcpy(ctn->pen_param, pattern, sizeof(pattern));
	ctn->pen_param_count = sizeof(pattern);
	ctn730_set_status(ctn, ST_NEED_APP_CHN_ENABLE);
	schedule_delayed_work(&ctn->set_work, 0);

	return size;
}

/* Stop charging, read the pen's Bluetooth address again, resume charging. */
static ssize_t reget_mac_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	bool go;
	int ret;

	ret = kstrtobool(buf, &go);
	if (ret)
		return ret;
	if (!go)
		return size;

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled)
		return -ENODEV;

	ctn730_set_status(ctn, ST_DETECTED);
	ctn->have_mac = false;
	schedule_delayed_work(&ctn->set_work, 0);

	return size;
}

/* Enable/disable the periodic battery level events while charging. */
static ssize_t info_report_store(struct device *dev, struct device_attribute *attr,
				 const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	bool enable;
	int ret;

	ret = kstrtobool(buf, &enable);
	if (ret)
		return ret;

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled)
		return -ENODEV;

	ctn->need_report_info = enable;
	ctn730_set_status(ctn, enable ? ST_NEED_INFO_ENABLE : ST_NEED_INFO_DISABLE);
	schedule_delayed_work(&ctn->set_work, msecs_to_jiffies(100));

	return size;
}

/* 1: enter the RF-on test mode (BIST); 0: hard reset back to normal mode. */
static ssize_t rf_on_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	bool enable;
	int ret;

	ret = kstrtobool(buf, &enable);
	if (ret)
		return ret;

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled)
		return -ENODEV;
	if (ctn->ext_cmd == EXT_CMD_UPDATE_FIRMWARE)
		return -EBUSY;

	ctn->ext_cmd = enable ? EXT_CMD_RF_ON : EXT_CMD_NONE;
	schedule_delayed_work(&ctn->rf_on_work, msecs_to_jiffies(10));

	return size;
}

/* Raw bytes (max 32) to send to the pen over the application channel. */
static ssize_t param_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	if (size > CTN730_PEN_PARAM_LEN)
		return -EINVAL;

	guard(mutex)(&ctn->lock);

	if (!ctn->enabled)
		return -ENODEV;

	memcpy(ctn->pen_param, buf, size);
	ctn->pen_param_count = size;
	ctn730_set_status(ctn, ST_NEED_APP_CHN_ENABLE);
	schedule_delayed_work(&ctn->set_work, msecs_to_jiffies(100));

	return size;
}

/*
 * Write the firmware version (e.g. 0x1041) to flash user_ee_hostcontrolled.bin
 * and wlc_host_user_app.bin into the chip. Only with allow_firmware_update=1.
 */
static ssize_t update_firmware_store(struct device *dev, struct device_attribute *attr,
				     const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	const struct firmware *ee = NULL, *app = NULL;
	u32 ee_size, app_size, total;
	u16 version;
	u8 *data;
	int ret;

	if (!allow_firmware_update)
		return -EPERM;

	ret = kstrtou16(buf, 0, &version);
	if (ret)
		return ret;
	if (!version)
		return -EINVAL;

	ret = request_firmware(&ee, CTN730_FW_USER_EE_NAME, ctn->dev);
	if (ret)
		return ret;
	ret = request_firmware(&app, CTN730_FW_USER_APP_NAME, ctn->dev);
	if (ret)
		goto out;

	/* The vendor tolerates one trailing byte after the 3072 byte image. */
	if (!ee->size || !app->size || ee->size > CTN730_FW_USER_EE_MAX + 1) {
		ret = -EINVAL;
		goto out;
	}
	ee_size = min_t(u32, round_up(ee->size, CTN730_FW_BLOCK), CTN730_FW_USER_EE_MAX);
	app_size = round_up(app->size, CTN730_FW_BLOCK);
	total = ee_size + app_size;

	data = kvzalloc(total, GFP_KERNEL);
	if (!data) {
		ret = -ENOMEM;
		goto out;
	}
	memcpy(data, ee->data, min_t(u32, ee->size, ee_size));
	memcpy(data + ee_size, app->data, app->size);

	scoped_guard(mutex, &ctn->lock) {
		if (!ctn->enabled || ctn->ext_cmd != EXT_CMD_NONE) {
			kvfree(data);
			ret = ctn->enabled ? -EBUSY : -ENODEV;
			goto out;
		}

		ctn730_fw_free(ctn);
		ctn->fw.data = data;
		ctn->fw.user_ee_size = ee_size;
		ctn->fw.size = total;
		ctn->fw.index = 0;
		ctn->fw.version[0] = version >> 8;
		ctn->fw.version[1] = version;
		/* CRC-32/IEEE 802.3 over the padded image */
		ctn->fw.crc = ~crc32_le(~0, data, total);
		ctn->ext_cmd = EXT_CMD_UPDATE_FIRMWARE;

		dev_warn(ctn->dev, "starting firmware download: %u bytes, crc %#010x\n",
			 total, ctn->fw.crc);
		/* The chip comes back in download mode and kicks the work. */
		ctn730_hard_reset(ctn);
	}
	ret = 0;
out:
	release_firmware(app);
	release_firmware(ee);
	return ret ?: size;
}

static ssize_t charge_state_show(struct device *dev, struct device_attribute *attr,
				 char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	return sysfs_emit(buf, "%s\n",
			  ctn730_charge_state_text[READ_ONCE(ctn->pen.charge_state)]);
}

static ssize_t mac_show(struct device *dev, struct device_attribute *attr,
			char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	u8 mac[6];

	scoped_guard(mutex, &ctn->lock)
		memcpy(mac, ctn->pen.mac, sizeof(mac));

	/* stored little endian, as read from the tag */
	return sysfs_emit(buf, "%02X:%02X:%02X:%02X:%02X:%02X\n",
			  mac[5], mac[4], mac[3], mac[2], mac[1], mac[0]);
}

static ssize_t uid_show(struct device *dev, struct device_attribute *attr,
			char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	guard(mutex)(&ctn->lock);
	return sysfs_emit(buf, "%7phN\n", ctn->pen.uid);
}

static ssize_t version_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	guard(mutex)(&ctn->lock);
	return sysfs_emit(buf, "%02x%02x\n", ctn->version[0], ctn->version[1]);
}

static ssize_t level_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	return sysfs_emit(buf, "%d\n", READ_ONCE(ctn->pen.level));
}

static ssize_t attached_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	return sysfs_emit(buf, "%d\n", READ_ONCE(ctn->pen.attached));
}

static ssize_t status_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	return sysfs_emit(buf, "%s\n", ctn730_status_text[READ_ONCE(ctn->status)]);
}

/* Reading triggers a BIST "activation" (tag presence / WLC capability test). */
static ssize_t cn_test_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);

	guard(mutex)(&ctn->lock);
	ctn730_cn_test(ctn);
	return sysfs_emit(buf, "%s\n", ctn730_status_text[ctn->status]);
}

/* Payload of the last BIST response: status byte, then data. */
static ssize_t bist_result_show(struct device *dev, struct device_attribute *attr,
				char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	int i, n = 0;

	guard(mutex)(&ctn->lock);
	for (i = 0; i < ctn->bist_result_len; i++)
		n += sysfs_emit_at(buf, n, "%02x ", ctn->bist_result[i]);
	if (n)
		n--;
	n += sysfs_emit_at(buf, n, "\n");
	return n;
}

/*
 * Diagnostics. None of these writes anything to the chip or to the pen.
 */

/*
 * "<page> [count]": read count * 16 bytes of the pen's NFC tag (NXP CRN120,
 * a Type 2 tag) starting at the given 4-byte page, through BIST 0x09. Only in
 * rf_on mode. The chip refuses pages below 12 (the NDEF area) with status
 * 0x32; a failed read (0x33) drops the session: write rf_on again. The
 * answer is left in bist_result.
 */
static ssize_t ntag_read_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t size)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	unsigned int page, count = 1;
	u8 cmd[3], resp[CTN730_MAX_PAYLOAD];
	int ret;

	if (sscanf(buf, "%i %i", &page, &count) < 1)
		return -EINVAL;
	if (page > 0xff || count < 1 || count > 15)
		return -EINVAL;

	scoped_guard(mutex, &ctn->lock) {
		if (!ctn->enabled)
			return -ENODEV;
		if (ctn->ext_cmd != EXT_CMD_RF_ON ||
		    (ctn->status != ST_RF_ON && ctn->status != ST_BIST_ERR))
			return -EBUSY;
	}

	cmd[0] = BIST_READ_NTAG_BLOCKS;
	cmd[1] = page;
	cmd[2] = count;
	ret = ctn730_query(ctn, HOST_CTRL_BIST, cmd, sizeof(cmd), resp, sizeof(resp));
	if (ret < 0)
		return ret;

	scoped_guard(mutex, &ctn->lock) {
		ctn->bist_result_len = ret;
		memcpy(ctn->bist_result, resp, ret);
	}
	return size;
}

/*
 * The chip's status items (DUMP_STATUS, tags 0..7) as "tag: status data",
 * then the answer to a CHARGING_INFO request. Tag 1 is the firmware
 * version; the meaning of the others is not public.
 */
static ssize_t chip_status_show(struct device *dev, struct device_attribute *attr,
				char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	u8 resp[CTN730_MAX_PAYLOAD];
	int n = 0, ret;
	u8 tag;

	scoped_guard(mutex, &ctn->lock) {
		if (!ctn->enabled)
			return -ENODEV;
		if (ctn->ext_cmd == EXT_CMD_UPDATE_FIRMWARE)
			return -EBUSY;
	}

	for (tag = 0; tag < CTN730_STATUS_TAGS; tag++) {
		ret = ctn730_query(ctn, HOST_CTRL_DUMP_STATUS, &tag, 1, resp, sizeof(resp));
		if (ret < 0)
			return ret;
		n += sysfs_emit_at(buf, n, "%02x: %*ph\n", tag, ret, resp);
	}

	ret = ctn730_query(ctn, CHG_CHARGING_INFO, NULL, 0, resp, sizeof(resp));
	if (ret < 0)
		return ret;
	n += sysfs_emit_at(buf, n, "charging_info: %*ph\n", ret, resp);

	return n;
}

/*
 * The chip's configuration parameters (user EEPROM) as "id: value", read
 * with READ_PARAMETER. The chip only answers this outside of detection, i.e.
 * in rf_on mode. Read only: this driver never writes parameters.
 */
static ssize_t chip_params_show(struct device *dev, struct device_attribute *attr,
				char *buf)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	u8 resp[CTN730_MAX_PAYLOAD];
	int n = 0, ret;
	u8 id;

	scoped_guard(mutex, &ctn->lock) {
		if (!ctn->enabled)
			return -ENODEV;
		if (ctn->ext_cmd == EXT_CMD_UPDATE_FIRMWARE)
			return -EBUSY;
	}

	for (id = 0; id < CTN730_PARAM_COUNT; id++) {
		ret = ctn730_query(ctn, HOST_CTRL_READ_PARAMETER, &id, 1, resp, sizeof(resp));
		if (ret < 0)
			return ret;
		if (ret < 1 || resp[0] != STATUS_OK) {
			n += sysfs_emit_at(buf, n, "%02x: error %02x\n", id,
					   ret ? resp[0] : 0xff);
			continue;
		}
		n += sysfs_emit_at(buf, n, "%02x: %*ph\n", id, ret - 1, resp + 1);
	}
	return n;
}

static DEVICE_ATTR_RW(enable);
static DEVICE_ATTR_WO(pen_cmd);
static DEVICE_ATTR_WO(reget_mac);
static DEVICE_ATTR_WO(info_report);
static DEVICE_ATTR_WO(rf_on);
static DEVICE_ATTR_WO(param);
static DEVICE_ATTR_WO(update_firmware);
static DEVICE_ATTR_RO(charge_state);
static DEVICE_ATTR_RO(mac);
static DEVICE_ATTR_RO(uid);
static DEVICE_ATTR_RO(version);
static DEVICE_ATTR_RO(level);
static DEVICE_ATTR_RO(attached);
static DEVICE_ATTR_RO(status);
static DEVICE_ATTR_RO(cn_test);
static DEVICE_ATTR_RO(bist_result);
static DEVICE_ATTR_WO(ntag_read);
static DEVICE_ATTR_ADMIN_RO(chip_status);
static DEVICE_ATTR_ADMIN_RO(chip_params);

static struct attribute *ctn730_attrs[] = {
	&dev_attr_enable.attr,
	&dev_attr_pen_cmd.attr,
	&dev_attr_reget_mac.attr,
	&dev_attr_info_report.attr,
	&dev_attr_rf_on.attr,
	&dev_attr_param.attr,
	&dev_attr_update_firmware.attr,
	&dev_attr_charge_state.attr,
	&dev_attr_mac.attr,
	&dev_attr_uid.attr,
	&dev_attr_version.attr,
	&dev_attr_level.attr,
	&dev_attr_attached.attr,
	&dev_attr_status.attr,
	&dev_attr_cn_test.attr,
	&dev_attr_bist_result.attr,
	&dev_attr_ntag_read.attr,
	&dev_attr_chip_status.attr,
	&dev_attr_chip_params.attr,
	NULL
};

static umode_t ctn730_attr_is_visible(struct kobject *kobj, struct attribute *attr,
				      int n)
{
	if (attr == &dev_attr_update_firmware.attr && !allow_firmware_update)
		return 0;
	return attr->mode;
}

static const struct attribute_group ctn730_group = {
	.attrs = ctn730_attrs,
	.is_visible = ctn730_attr_is_visible,
};

static const struct attribute_group *ctn730_groups[] = {
	&ctn730_group,
	NULL
};

/* Same variables as the vendor driver; the stock framework listens to them. */
static int ctn730_uevent(const struct device *dev, struct kobj_uevent_env *env)
{
	struct ctn730 *ctn = dev_to_ctn730(dev);
	const u8 *mac = ctn->pen.mac;
	int level = READ_ONCE(ctn->pen.level);
	int ret;

	/* Called with ctn->lock held (ctn730_notify) or for "add": no locking. */
	if (ctn->app_data_ok) {
		ret = add_uevent_var(env, "WRITEPENDATA=%d", ctn->app_data_ok == 2);
		if (ret)
			return ret;
	}
	ret = add_uevent_var(env, "ATTACHED=%d", READ_ONCE(ctn->pen.attached));
	if (ret)
		return ret;
	ret = add_uevent_var(env, "CHARGING_STATE=%s",
			     ctn730_charge_state_text[READ_ONCE(ctn->pen.charge_state)]);
	if (ret)
		return ret;
	if (level != -1) {
		ret = add_uevent_var(env, "LEVEL=%d", level);
		if (ret)
			return ret;
	}
	return add_uevent_var(env, "MAC=%02X:%02X:%02X:%02X:%02X:%02X",
			      mac[5], mac[4], mac[3], mac[2], mac[1], mac[0]);
}

static const struct device_type ctn730_dev_type = {
	.name = "nfc_charger",
	.uevent = ctn730_uevent,
};

/* -------------------------------------------------------------------------
 * Probe / remove
 */

static void ctn730_remove_lookup(void *data)
{
	gpiod_remove_lookup_table(data);
}

/*
 * Bring-up fallback for a device created from userspace (no firmware node):
 * describe the GPIOs with a machine lookup table built from the module
 * parameters. A device tree node is the supported way; see README.md.
 */
static int ctn730_add_fallback_lookup(struct device *dev)
{
	static const struct {
		const char *con_id;
		char **param;
		unsigned long flags;
	} map[] = {
		{ "enable", &enable_gpio, GPIO_ACTIVE_HIGH },
		{ "reset", &reset_gpio, GPIO_ACTIVE_LOW },
		{ "irq", &irq_gpio, GPIO_ACTIVE_HIGH },
	};
	struct gpiod_lookup_table *table;
	unsigned int i, n = 0, offset;
	char *label, *sep;

	table = devm_kzalloc(dev, struct_size(table, table, ARRAY_SIZE(map) + 1),
			     GFP_KERNEL);
	if (!table)
		return -ENOMEM;

	for (i = 0; i < ARRAY_SIZE(map); i++) {
		if (!*map[i].param || !**map[i].param)
			continue;

		label = devm_kstrdup(dev, *map[i].param, GFP_KERNEL);
		if (!label)
			return -ENOMEM;
		sep = strrchr(label, ',');
		if (!sep || kstrtouint(sep + 1, 0, &offset))
			return dev_err_probe(dev, -EINVAL,
					     "bad %s_gpio parameter, want \"<chip label>,<offset>\"\n",
					     map[i].con_id);
		*sep = '\0';

		table->table[n++] = GPIO_LOOKUP(label, offset, map[i].con_id,
						map[i].flags);
	}
	if (!n)
		return 0;

	table->dev_id = dev_name(dev);
	gpiod_add_lookup_table(table);
	dev_notice(dev, "no firmware node: using GPIOs from module parameters\n");

	return devm_add_action_or_reset(dev, ctn730_remove_lookup, table);
}

static int ctn730_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	unsigned long irqflags = IRQF_ONESHOT | IRQF_NO_AUTOEN;
	struct gpio_desc *irq_gpiod;
	struct ctn730 *ctn;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENODEV;

	ctn = devm_kzalloc(dev, sizeof(*ctn), GFP_KERNEL);
	if (!ctn)
		return -ENOMEM;

	ctn->dev = dev;
	ctn->client = client;
	ctn->pen.level = -1;
	/* Battery level events are on by default in the chip. */
	ctn->report_info = true;
	ctn->need_report_info = true;
	i2c_set_clientdata(client, ctn);

	ret = devm_mutex_init(dev, &ctn->power_lock);
	if (ret)
		return ret;
	ret = devm_mutex_init(dev, &ctn->lock);
	if (ret)
		return ret;
	ret = devm_mutex_init(dev, &ctn->query_lock);
	if (ret)
		return ret;
	init_completion(&ctn->query_done);

	INIT_DELAYED_WORK(&ctn->set_work, ctn730_set_work);
	INIT_DELAYED_WORK(&ctn->rf_on_work, ctn730_rf_on_work);
	INIT_DELAYED_WORK(&ctn->update_firmware_work, ctn730_update_firmware_work);
	INIT_DELAYED_WORK(&ctn->check_static_charge_work,
			  ctn730_check_static_charge_work);
	INIT_DELAYED_WORK(&ctn->boot_work, ctn730_boot_work);
	INIT_WORK(&ctn->psy_work, ctn730_psy_work);

	if (!dev_fwnode(dev)) {
		ret = ctn730_add_fallback_lookup(dev);
		if (ret)
			return ret;
	}

	/* VEN low: the chip is off until ctn730_enable(). */
	ctn->enable_gpiod = devm_gpiod_get_optional(dev, "enable", GPIOD_OUT_LOW);
	if (IS_ERR(ctn->enable_gpiod))
		return dev_err_probe(dev, PTR_ERR(ctn->enable_gpiod),
				     "cannot get enable GPIO\n");

	ctn->reset_gpiod = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ctn->reset_gpiod))
		return dev_err_probe(dev, PTR_ERR(ctn->reset_gpiod),
				     "cannot get reset GPIO\n");

	ctn->irq = client->irq;
	if (ctn->irq <= 0) {
		irq_gpiod = devm_gpiod_get(dev, "irq", GPIOD_IN);
		if (IS_ERR(irq_gpiod))
			return dev_err_probe(dev, PTR_ERR(irq_gpiod),
					     "no interrupt and no irq GPIO\n");
		ctn->irq = gpiod_to_irq(irq_gpiod);
		if (ctn->irq < 0)
			return dev_err_probe(dev, ctn->irq, "cannot map irq GPIO\n");
		irqflags |= IRQF_TRIGGER_HIGH;
	}

	ret = devm_request_threaded_irq(dev, ctn->irq, NULL, ctn730_irq_thread,
					irqflags, "ctn730", ctn);
	if (ret)
		return dev_err_probe(dev, ret, "cannot request interrupt\n");

	ctn->misc.minor = MISC_DYNAMIC_MINOR;
	ctn->misc.name = "ctn730";
	ctn->misc.nodename = "ctn730";
	ctn->misc.parent = dev;
	ctn->misc.groups = ctn730_groups;
	ret = misc_register(&ctn->misc);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register misc device\n");
	/* For the ATTACHED=/CHARGING_STATE=/LEVEL=/MAC= uevent variables. */
	ctn->misc.this_device->type = &ctn730_dev_type;
	scoped_guard(mutex, &ctn->lock)
		ctn->misc_registered = true;

	if (enable_on_probe)
		ctn730_enable(ctn);

	return 0;
}

static void ctn730_remove(struct i2c_client *client)
{
	struct ctn730 *ctn = i2c_get_clientdata(client);

	/* No more uevents and no re-enable from sysfs. */
	scoped_guard(mutex, &ctn->lock)
		ctn->removing = true;

	/* Drains the sysfs handlers. */
	misc_deregister(&ctn->misc);

	/* Chip off, interrupt masked, state machines stopped. */
	ctn730_disable(ctn);

	cancel_work_sync(&ctn->psy_work);
	if (ctn->psy)
		power_supply_unregister(ctn->psy);
}

static void ctn730_shutdown(struct i2c_client *client)
{
	struct ctn730 *ctn = i2c_get_clientdata(client);

	scoped_guard(mutex, &ctn->lock)
		ctn->removing = true;
	ctn730_disable(ctn);
}

static int ctn730_suspend(struct device *dev)
{
	struct ctn730 *ctn = dev_get_drvdata(dev);
	bool wait = false;

	guard(mutex)(&ctn->power_lock);
	if (pm_suspend_target_state == PM_SUSPEND_TO_IDLE &&
	    READ_ONCE(suspend_ven_off) && ctn->enable_gpiod &&
	    device_property_read_bool(dev, "nxp,q706f-allow-suspend-ven-off") &&
	    !device_may_wakeup(dev)) {
		scoped_guard(mutex, &ctn->lock) {
			if (ctn->enabled && ctn->ext_cmd == EXT_CMD_UPDATE_FIRMWARE)
				return -EBUSY;
		}
		ctn->suspend_ven_released = ctn730_disable_locked(ctn, true);
		if (ctn->suspend_ven_released) {
			dev_info(dev, "VEN released for suspend\n");
			return 0;
		}
	}

	/*
	 * The chip keeps charging on its own while the host sleeps. Stop the
	 * periodic battery level events so they do not wake the system when
	 * the interrupt is a wakeup source.
	 */
	scoped_guard(mutex, &ctn->lock) {
		if (ctn->enabled && ctn->report_info &&
		    ctn->status == ST_DETECTED && ctn->have_mac) {
			ctn730_set_charging_info(ctn, false);
			wait = true;
		}
	}
	if (wait)
		msleep(30);	/* let the response come in */

	if (ctn->enabled) {
		disable_irq(ctn->irq);
		ctn->suspend_irq_masked = true;
	}

	return 0;
}

static int ctn730_resume(struct device *dev)
{
	struct ctn730 *ctn = dev_get_drvdata(dev);

	guard(mutex)(&ctn->power_lock);
	if (ctn->suspend_ven_released) {
		ctn->suspend_ven_released = false;
		return ctn730_enable_locked(ctn);
	}

	if (!ctn->suspend_irq_masked)
		return 0;

	/* Events latched during suspend are handled now (level IRQ). */
	ctn->suspend_irq_masked = false;
	enable_irq(ctn->irq);

	scoped_guard(mutex, &ctn->lock) {
		if (ctn->need_report_info && !ctn->report_info &&
		    ctn->status == ST_DETECTED && ctn->have_mac)
			ctn730_set_charging_info(ctn, true);
	}

	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(ctn730_pm_ops, ctn730_suspend, ctn730_resume);

static const struct of_device_id ctn730_of_match[] = {
	{ .compatible = "nxp,ctn730" },
	{ }
};
MODULE_DEVICE_TABLE(of, ctn730_of_match);

static const struct i2c_device_id ctn730_id[] = {
	{ "ctn730" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, ctn730_id);

static struct i2c_driver ctn730_driver = {
	.probe = ctn730_probe,
	.remove = ctn730_remove,
	.shutdown = ctn730_shutdown,
	.id_table = ctn730_id,
	.driver = {
		.name = "ctn730",
		.of_match_table = ctn730_of_match,
		.pm = pm_sleep_ptr(&ctn730_pm_ops),
	},
};
module_i2c_driver(ctn730_driver);

MODULE_DESCRIPTION("NXP CTN730 NFC wireless stylus charger driver");
MODULE_LICENSE("GPL");
