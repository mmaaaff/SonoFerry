#!/usr/bin/env python3
"""Read-only installed-build checks. Never installs, restarts or starts playback."""
import argparse
import concurrent.futures
import datetime
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import time

from build_settings import PRODUCT_NAME, ENGINE_BUNDLE_PATH, CAPTURE_BUNDLE_PATH, DRIVER_PATH, ENGINE_HASH_KEY

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = pathlib.Path('/Applications') / (PRODUCT_NAME + '.app')
ENGINE = APP / ENGINE_BUNDLE_PATH
HAL = pathlib.Path(DRIVER_PATH)


def now():
    return datetime.datetime.now().astimezone().isoformat()


def run(args, timeout=12):
    start = time.monotonic()
    result = {'time': now(), 'timeoutSeconds': timeout}
    try:
        p = subprocess.run([str(a) for a in args], capture_output=True,
                           text=True, timeout=timeout)
        result.update(exitCode=p.returncode, stdout=p.stdout.strip(), stderr=p.stderr.strip())
    except subprocess.TimeoutExpired:
        result['error'] = '查询超时'
    except OSError as e:
        result['error'] = str(e)
    result['durationSeconds'] = round(time.monotonic() - start, 3)
    return result


def processes():
    result = run(['/bin/ps', '-axo', 'pid,ppid,%cpu,state,etime,comm'], 8)
    rows = []
    for line in result.pop('stdout', '').splitlines():
        parts = line.strip().split(None, 5)
        if len(parts) != 6 or ('coreaudiod' not in parts[5] and 'SonoFerry' not in parts[5]):
            continue
        try:
            rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]), cpu=float(parts[2]),
                             state=parts[3], elapsed=parts[4], command=parts[5]))
        except ValueError:
            result['error'] = '无法解析进程行：' + line.strip()
    result['processes'] = rows
    return result


def installed_checks(version, build):
    result = {'components': [], 'issues': []}
    versions = []
    hal_hash = None
    for path in (APP, ENGINE, ENGINE / CAPTURE_BUNDLE_PATH, HAL):
        item = {'path': str(path)}
        try:
            info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
            item.update(version=info.get('CFBundleShortVersionString'), build=info.get('CFBundleVersion'))
            if path == HAL:
                hal_hash = info.get(ENGINE_HASH_KEY)
                item['engineCDHash'] = hal_hash
            else:
                versions.append((item['version'], item['build']))
                if ((version and item['version'] != version) or (build and item['build'] != build)):
                    result['issues'].append('版本与目标不符：' + str(path))
        except (OSError, ValueError, plistlib.InvalidFileException) as e:
            item['error'] = str(e)
            result['issues'].append('无法读取组件版本：' + str(path))
        item['signature'] = run(['/usr/bin/codesign', '--verify', '--deep', '--strict', path])
        if item['signature'].get('exitCode') != 0:
            result['issues'].append('组件签名失败或超时：' + str(path))
        result['components'].append(item)
    if len(versions) != 3 or len(set(versions)) != 1:
        result['issues'].append('App／引擎／音频 helper 的版本不一致或缺失，需核对交付说明')
    result['engineSignature'] = run(['/usr/bin/codesign', '-d', '--verbose=4', ENGINE])
    match = re.search(r'^CDHash=(\S+)$', result['engineSignature'].get('stderr', ''), re.M)
    result['engineCDHash'] = match.group(1) if match else None
    if result['engineSignature'].get('exitCode') != 0 or not hal_hash or result['engineCDHash'] != hal_hash:
        result['issues'].append('引擎与 HAL 授权哈希未能确认匹配')
    result['doctor'] = run([ENGINE / 'Contents/MacOS/SonoFerryEngine', '--doctor'])
    try:
        doctor = json.loads(result['doctor'].get('stdout', ''))
        details = doctor['details']
        if result['doctor'].get('exitCode') != 0 or doctor.get('kind') != 'doctor':
            raise ValueError('doctor 失败')
        result['driverRevision'] = details.get('driverRevision')
        if not str(result['driverRevision']).isdigit() or int(result['driverRevision']) <= 0:
            raise ValueError('未取得已加载驱动 revision')
        if details.get('controllerAvailable') != 'true' or details.get('classicPeerSelector') != 'true':
            result['issues'].append('doctor 未确认蓝牙控制器／Classic 接口可用')
        if str(details.get('bluetoothAuthorization')) != '3':
            result['issues'].append('蓝牙权限不是当前已授权状态，请检查 doctor 输出')
    except (ValueError, KeyError, TypeError, AttributeError):
        result['issues'].append('doctor 失败、超时或未确认已加载驱动')
    if str(result.get('driverRevision', '')).isdigit() and int(result['driverRevision']) >= 7:
        result['startupHealth'] = run([ENGINE / 'Contents/MacOS/SonoFerryEngine', '--startup-health'])
        try:
            startup = json.loads(result['startupHealth'].get('stdout', ''))
            if result['startupHealth'].get('exitCode') != 0 or startup.get('driverQueryError'):
                raise ValueError('loaded HAL query failed')
            if not result.get('engineCDHash') or startup.get('loadedEngineCDHash') != result['engineCDHash']:
                result['issues'].append('已加载 HAL 的引擎哈希不匹配，需要重新加载音频服务或重启 Mac')
        except (ValueError, TypeError, AttributeError):
            result['issues'].append('已加载 HAL 身份检查失败或超时')
    result['receipt'] = run(['/usr/sbin/pkgutil', '--pkg-info', 'local.SonoFerry.package'])
    if result['receipt'].get('exitCode') != 0:
        result['issues'].append('未能读取安装收据')
    return result


def assess_samples(samples):
    issues = []
    for sample in samples:
        if sample.get('exitCode') != 0 or sample.get('error'):
            issues.append('进程采样失败或超时，不能确认 CPU 健康')
            break
    for label, marker in (('coreaudiod', '/usr/sbin/coreaudiod'), ('HAL', 'Core Audio Driver (SonoFerry.driver)')):
        groups = [[p for p in s['processes'] if p['command'] == marker] for s in samples]
        # Allow startup to finish before requiring a single stable service process.
        steady = groups[1:]
        if any(len(g) != 1 for g in steady):
            issues.append(label + '在后面三次采样中缺失或有多实例')
        observed = [p for group in groups for p in group]
        if len({p['pid'] for p in observed}) > 1:
            issues.append(label + '的 PID 在观察期间变化，请确认是否反复退出')
        if any('Z' in p['state'] or 'T' in p['state'] for p in observed):
            issues.append(label + '出现僵尸或暂停状态')
        if all(len(g) == 1 and g[0]['cpu'] >= 50 for g in steady):
            issues.append(label + '连续三次 CPU ≥50%，先停止播放测试并检查原因')
    return issues


def main():
    parser = argparse.ArgumentParser(description='只读检查安装版本、匹配 HAL、doctor 和 45 秒 CPU／PID；不会安装或重启。')
    parser.add_argument('--baseline', action='store_true', help='只采样一次安装前进程基线，不运行 doctor')
    parser.add_argument('--version', help='预期 App／引擎／helper 版本，例如 0.1.27')
    parser.add_argument('--build', help='预期 build，例如 28')
    args = parser.parse_args()
    report = {'startedAt': now(), 'readOnly': True, 'baselineOnly': args.baseline,
              'expectedVersion': args.version, 'expectedBuild': args.build, 'samples': []}
    output = ROOT / '.build' / ('health-check-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.json')
    output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    print('仅只读检查；请保持 SonoFerry 退出、暂停其他音频。', flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = None if args.baseline else pool.submit(installed_checks, args.version, args.build)
        start = time.monotonic()
        for offset in ([0] if args.baseline else [0, 15, 30, 45]):
            time.sleep(max(0, start + offset - time.monotonic()))
            sample = processes()
            sample['elapsedSeconds'] = round(time.monotonic() - start, 3)
            report['samples'].append(sample)
            save()
            print(f"\n{sample['time']}  观察 {sample['elapsedSeconds']} 秒", flush=True)
            for p in sample['processes']:
                print(f"PID {p['pid']:>6}  CPU {p['cpu']:5.1f}%  {p['state']:<4}  {p['command']}", flush=True)
        if future:
            report['checks'] = future.result()
    if args.baseline:
        report['issues'] = ['进程基线读取失败'] if report['samples'][0].get('exitCode') != 0 else []
    else:
        report['issues'] = report['checks']['issues'] + assess_samples(report['samples'])
        print('\n组件版本：', flush=True)
        for c in report['checks']['components']:
            print(f"{c['path']}: {c.get('version', '未知')} / build {c.get('build', '未知')}")
        print('已加载驱动 revision:', report['checks'].get('driverRevision', '未知'))
    report['finishedAt'] = now()
    save()
    for issue in report['issues']:
        print('需检查：' + issue)
    if not report['issues']:
        print('基线已记录。' if args.baseline else '版本／签名／HAL／doctor 检查通过；采样未触发异常提示。')
    print('记录：' + str(output), flush=True)
    if not args.baseline:
        print('CPU 阈值仅作提醒；请结合实际音频活动看数值。此检查不验证蓝牙播放、HAL 租约或历史故障根因。')
    return 1 if report['issues'] else 0


if __name__ == '__main__':
    sys.exit(main())
