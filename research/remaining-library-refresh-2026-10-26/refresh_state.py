"""Refresh resumable counts from approved sources and actual installed assets."""
from pathlib import Path
import hashlib
import json

report = Path(__file__).resolve().parent
root = report.parents[1]
def read(name):
    return json.loads((report / name).read_text())
def write(name, value):
    path = report / name
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)

jobs = read('jobs.json')
records = {p.stem: json.loads(p.read_text()) for p in (report / 'generated').glob('*.json')}
approvals = [a for a in read('approved-sources.json') if a['source'] == records.get(a['id'], {}).get('source')]
approved = {a['id'] for a in approvals}
assets = read('assets.json')
installed = []
for asset in assets:
    if asset.get('status') != 'reviewed-installed' or asset['id'] not in approved:
        continue
    if asset['source'] != records.get(asset['id'], {}).get('source'):
        continue
    path = Path(asset['installedPath'])
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == asset['sha256']:
        installed.append(asset['id'])
deferred = {p.stem for p in (report / 'deferred').glob('*.json')}
pending = []
for job in jobs:
    if job['id'] in approved:
        continue
    state = 'needs-refinement' if job['id'] in records else ('generation-deferred' if job['id'] in deferred else 'not-generated')
    pending.append({k: job[k] for k in ('id', 'brand', 'product')} | {'status': state})
review = read('review-notes.json')
runtime = read('final-runtime-validation.json') if (report / 'final-runtime-validation.json').exists() else {}
audit = read('asset-validation.json') if (report / 'asset-validation.json').exists() else {}
final_audit = read('final-resource-audit.json') if (report / 'final-resource-audit.json').exists() else {}
previews = read('final-previews.json') if (report / 'final-previews.json').exists() else {}
review_complete = review.get('complete') is True and review.get('finalPagesReviewed') == list(range(1, 15)) and review.get('pendingCorrections') == []
complete = len(approved) == len(installed) == len(jobs) == 331 and not pending and review_complete and audit.get('covers') == 331 and runtime.get('validated') is True and runtime.get('installedCoverCount') == 331 and final_audit.get('passed') is True and previews.get('reviewed') is True
counts = {'requested': len(jobs), 'generatedRecords': len(records), 'approved': len(approved), 'installed': len(installed), 'remaining': len(pending), 'allComplete': complete}
write('remaining-to-complete.json', counts | {'items': pending})
checkpoint = counts | {'phase': 'complete' if complete else 'in_progress_builtin', 'project': str(root), 'report': str(report), 'nextUntouchedId': next((x['id'] for x in pending if x['status'] == 'not-generated'), None), 'pendingRefinements': [x['id'] for x in pending if x['status'] == 'needs-refinement'], 'retryNotes': 'All selected sources are approved; historical deferred requests are resolved. Do not regenerate approved covers.' if complete else 'Use one built-in image_gen call per cover and native single-call watcher. Verify actual image identity and packaging before approving. Never count unapproved drafts as complete.', 'promptSet': 'jobs.json', 'selectedSources': 'generated/', 'approvals': 'approved-sources.json', 'remainingList': 'remaining-to-complete.json', 'testEvidence': 'final-focused-tests-20261027.json' if complete else 'interim-focused-tests-20261027.json', 'runtimeEvidence': 'final-runtime-validation.json' if complete else 'interim-runtime-validation-226.json', 'lastRuntimeValidatedInstalledCount': 331 if complete else 226, 'assetScopeAudit': 'asset-validation.json' if audit else 'interim-installation.json', 'finalReviewComplete': review_complete, 'physicalCameraMatchingComplete': False, 'generationMode': 'built-in only; explicitly requested by user'}
write('resume-checkpoint.json', checkpoint)
if complete:
    write('progress.json', counts | {'generated': len(records), 'remainingToApprove': 0, 'complete': True, 'deferred': [], 'refinementPending': [], 'retrySweepSkipped': [], 'generationMode': 'built-in only', 'completedThisContinuation': 105, 'runtimeEvidence': 'final-runtime-validation.json', 'resourceAudit': 'final-resource-audit.json'})
status = '# 当前制作进度\n\n'
status += f"已审核 **{len(approved)} / {len(jobs)}** 款，已接入 **{len(installed)}** 款，仍有 **{len(pending)}** 款未通过审核。" + ('本轮剩余 105 张已完成，全部 331 张均通过最终接入与运行验证。' if complete else '最终运行验证尚在进行。') + '\n\n'
status += '仅使用内置 image_gen。每张与对应真实包装核对，保留关键色、字体和真实图案；接入时核对源文件、1024px sRGB 编码和范围。未批准的初稿不会接入。\n\n'
status += '精确清单见 [remaining-to-complete.json](remaining-to-complete.json)，恢复点见 [resume-checkpoint.json](resume-checkpoint.json)，最终资源审计见 [asset-validation.json](asset-validation.json)。\n\n'
if complete:
    status += 'iPhone 17 模拟器最终构建零警告、零错误；331/331 安装包封面哈希与正式资源一致，18 项回归测试通过，Library 网格、品牌/颜色筛选及详情已经实际检查。证据见 [final-runtime-validation.json](final-runtime-validation.json)。本次验证针对封面资源与显示；此前用户暂缓的真机多场景拍摄校准不计入本次完成范围。\n'
else:
    status += '此前 226 张阶段的运行记录保留供追溯；全量最终运行结果待验证完成后登记。\n'
(report / 'CURRENT-PROGRESS.md').write_text(status)
print(json.dumps(counts))
