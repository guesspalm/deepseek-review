#!/usr/bin/env nu
# Author: hustcer
# Created: 2025/04/02 20:02:15
# Description: Diff command for DeepSeek-Review

use common.nu [GITHUB_API_BASE, ECODE, git-check, has-ref]
use util.nu [generate-include-regex, generate-exclude-regex, prepare-awk, is-safe-git]

# If the PR title or body contains any of these keywords, skip the review
const IGNORE_REVIEW_KEYWORDS = ['skip review' 'skip cr']

# Get the diff content from GitHub PR or local git changes and apply filters
export def get-diff [
  --repo: string,       # GitHub repository name
  --pr-number: string,  # GitHub PR number
  --diff-to: string,    # Diff to git ref
  --diff-from: string,  # Diff from git ref
  --include: string,    # Comma separated file patterns to include in the code review
  --exclude: string,    # Comma separated file patterns to exclude in the code review
  --patch-cmd: string,  # The `git show` or `git diff` command to get the diff content
] {
  let content = (
    get-diff-content --repo $repo --pr-number $pr_number --patch-cmd $patch_cmd
      --diff-to $diff_to --diff-from $diff_from --include $include --exclude $exclude)

  if ($content | is-empty) {
    print $'(ansi g)Nothing to review.(ansi reset)'
    exit $ECODE.SUCCESS
  }

  apply-file-filters $content --include $include --exclude $exclude
}

# Get diff content from GitHub PR or local git changes
def get-diff-content [
  --repo: string,       # GitHub repository name
  --pr-number: string,  # GitHub PR number
  --diff-to: string,    # Diff to git ref
  --diff-from: string,  # Diff from git ref
  --include: string,    # Comma separated file patterns to include in the code review
  --exclude: string,    # Comma separated file patterns to exclude in the code review
  --patch-cmd: string,  # The `git show` or `git diff` command to get the diff content
] {
  let local_repo = $env.PWD

  if ($pr_number | is-not-empty) {
    get-pr-diff --repo $repo $pr_number
  } else if ($diff_from | is-not-empty) {
    get-ref-diff $diff_from --diff-to $diff_to
  } else if not (git-check $local_repo --check-repo=1) {
    print $'Current directory ($local_repo) is (ansi r)NOT(ansi reset) a git repo, bye...(char nl)'
    exit $ECODE.CONDITION_NOT_SATISFIED
  } else if ($patch_cmd | is-not-empty) {
    get-patch-diff $patch_cmd
  } else {
    git diff
  }
}

# Get the diff content of the specified GitHub PR,
# if the PR description contains the skip keyword, exit
def get-pr-diff [
  --repo: string,       # GitHub repository name
  pr_number: string,    # GitHub PR number
] {
  let BASE_HEADER = [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github.v3+json]
  let DIFF_HEADER = [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github.v3.diff]

  if ($repo | is-empty) {
    print $'(ansi r)Please provide the GitHub repository name by `--repo` option.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }

  let description = http get -H $BASE_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)'
                    | select title body | values | str join "\n"

  # Check if the PR title or body contains keywords to skip the review
  if ($IGNORE_REVIEW_KEYWORDS | any {|it| $description =~ $it }) {
    print $'(ansi r)The PR title or body contains keywords to skip the review, bye...(ansi reset)'
    exit $ECODE.SUCCESS
  }

  # Get the diff content of the PR
  # Try diff format API first, fallback to JSON API if 406 error occurs
  try {
    http get -H $DIFF_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)' | str trim
  } catch {|err|
    let err_text = try { $err | describe } catch { "" }
    let rendered = try { $err | get rendered } catch { "" }

    # 首先尝试检查错误是否包含406状态码的各种可能形式
    if ($err_text =~ '406') or ($rendered =~ '406') or ($err_text =~ 'Not Acceptable') {
      print $'(ansi y)Diff API returned 406 error, switching to JSON API...(ansi reset)'
      try {
        get-pr-changes-json --repo $repo --pr-number $pr_number
      } catch {|json_err|
        print $'(ansi r)Failed to get PR changes using JSON API: (ansi reset)'
        $json_err | print
        exit $ECODE.SERVER_ERROR
      }
    } else {
      print $'(ansi r)Failed to get PR diff: (ansi reset)'
      $err | print
      exit $ECODE.SERVER_ERROR
    }
  }
}

# Get PR changes using the JSON API and format them as diff content
# This is a fallback for large PRs when the diff API returns 406 error
def get-pr-changes-json [
  --repo: string,       # GitHub repository name
  --pr-number: string,  # GitHub PR number
] {
  let API_HEADER = [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github.v3+json]
  let nl = (char nl) # 使用char nl来表示换行符
  
  # 支持分页处理的函数
  def get-all-pr-files [
    repo: string,
    pr_number: string,
    headers: list,
    page: int = 1,
    per_page: int = 100,
    acc: list = []
  ] {
    # 发送API请求，带分页参数
    let url = $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)/files?page=($page)&per_page=($per_page)'
    let response = http get -H $headers $url
    
    # 如果返回为空，返回当前累积结果
    if ($response | length) == 0 { return $acc }
    
    # 合并当前页结果
    let all_files = ($acc | append $response)
    
    # 如果当前页结果少于每页数量，说明已经获取完所有文件
    if ($response | length) < $per_page {
      return $all_files
    }
    
    # 递归获取下一页
    get-all-pr-files $repo $pr_number $headers ($page + 1) $per_page $all_files
  }

  print $'(ansi y)Retrieving PR files using paginated API...(ansi reset)'
  
  # 获取所有PR文件
  let files = get-all-pr-files $repo $pr_number $API_HEADER
  
  if ($files | length) == 0 {
    print $'(ansi y)No files found in PR.(ansi reset)'
    return ""
  }
  
  print $'(ansi g)Found ($files | length) files in PR, formatting as diff...(ansi reset)'
  
  # 用字符串累加的方式构建输出，避免一次性处理大量数据
  mut result = ""
  
  # 逐个处理文件
  for file in $files {
    try {
      let path = $file.filename
      let status = $file.status
      let patch = $file.patch? | default ''
      
      # 获取并处理SHA值
      let sha_before = if ($file.sha? | is-empty) { '0000000' } else {
        $file.sha? | str substring 0..8  # 只取前8位
      }
      let sha_after = if ($file.sha? | is-empty) { '0000000' } else {
        $file.sha? | str substring 0..8  # 只取前8位
      }
      
      # 构建这个文件的diff内容
      let file_diff = (
        $'diff --git a/($path) b/($path)($nl)'
        + (if $file.previous_filename? != null {
            $'similarity index 100%($nl)rename from ($file.previous_filename)($nl)rename to ($path)($nl)'
          } else {
            # 使用正确的index行格式：index <old_sha>..<new_sha> <mode>
            $'index ($sha_before)..($sha_after) 100644($nl)'
          })
        + (if $status == 'added' {
            $'--- /dev/null($nl)+++ b/($path)($nl)'
          } else if $status == 'removed' {
            $'--- a/($path)($nl)+++ /dev/null($nl)'
          } else {
            $'--- a/($path)($nl)+++ b/($path)($nl)'
          })
      )

      # 处理patch内容，确保它包含正确的@@行
      let processed_patch = if ($patch | is-empty) {
        # 如果没有patch内容，生成一个空的patch
        $'@@ -0,0 +1,0 @@($nl)'
      } else {
        # 确保patch内容以@@开头
        if ($patch | str starts-with "@@") {
          # 替换patch中的\n为实际的换行符
          $patch | str replace -a '\n' $nl
        } else {
          $'@@ -1,1 +1,1 @@($nl)' + ($patch | str replace -a '\n' $nl)
        }
      }

      # 追加到结果字符串，确保每个文件的diff之间有一个空行
      $result = $result + $file_diff + $processed_patch + $nl
    } catch {|e|
      # 如果处理某个文件失败，记录错误并继续处理其他文件
      print $'(ansi y)Warning: Could not process file: ($file.filename?)(ansi reset)'
    }
  }

  # 如果结果为空，表明PR可能只有二进制文件或其他无法处理的内容
  if ($result | is-empty) {
    print $'(ansi y)No processable diff content found in PR.(ansi reset)'
    return ""
  }
  
  $result
}

# Get diff content from local git changes
def get-ref-diff [
  diff_from: string,    # Diff from git REF
  --diff-to: string,    # Diff to git ref
] {
  # Validate the git refs
  if not (has-ref $diff_from) {
    print $'(ansi r)The specified git ref ($diff_from) does not exist, please check it again.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }

  if ($diff_to | is-not-empty) and not (has-ref $diff_to) {
    print $'(ansi r)The specified git ref ($diff_to) does not exist, please check it again.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }

  git diff $diff_from ($diff_to | default HEAD)
}

# Get the diff content from the specified git command
def get-patch-diff [
  cmd: string  # The `git show` or `git diff` command to get the diff content
] {
  let valid = is-safe-git $cmd
  if not $valid {
    exit $ECODE.INVALID_PARAMETER
  }

  # Get the diff content from the specified git command
  nu -c $cmd
}

# Apply file filters to the diff content to include or exclude specific files
def apply-file-filters [
  content: string,      # The diff content to filter
  --include: string,    # Comma separated file patterns to include in the code review
  --exclude: string,    # Comma separated file patterns to exclude in the code review
] {
  mut filtered_content = $content
  let awk_bin = (prepare-awk)
  let outdated_awk = $'If you are using an (ansi r)outdated awk version(ansi reset), please upgrade to the latest version or use gawk latest instead.'

  if ($include | is-not-empty) {
    let patterns = $include | split row ','
    $filtered_content = $filtered_content | try {
      ^$awk_bin (generate-include-regex $patterns)
    } catch {
      print $outdated_awk
      exit $ECODE.OUTDATED
    }
  }

  if ($exclude | is-not-empty) {
    let patterns = $exclude | split row ','
    $filtered_content = $filtered_content | try {
      ^$awk_bin (generate-exclude-regex $patterns)
    } catch {
      print $outdated_awk
      exit $ECODE.OUTDATED
    }
  }
  # Check if filtered content is empty after applying filters
  if ($filtered_content | is-empty) or ($filtered_content | str trim | is-empty) {
    print $'(ansi g)No matching files to review after filtering. Review skipped.(ansi reset)'
    exit $ECODE.SUCCESS
  }

  $filtered_content
}
