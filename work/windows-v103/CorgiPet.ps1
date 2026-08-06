param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'CorgiPet-V103-7DDB3905', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

$atlasPath = Join-Path $PSScriptRoot 'assets\spritesheet.png'
if (-not (Test-Path -LiteralPath $atlasPath)) {
    [System.Windows.MessageBox]::Show("找不到动画资源：`n$atlasPath", '柯基小小') | Out-Null
    exit 1
}

$cellWidth = 192
$cellHeight = 208
$columns = 8
$rows = @{
    RunningRight = 0
    Dance = 1
    Jump = 2
    SleepEntryFirst = 3
    SleepEntrySecond = 4
    SleepIdle = 5
    Petting = 6
    Roll = 7
    Spin = 8
    GazeFirstHalf = 9
    GazeSecondHalf = 10
    CompanionEntry = 11
    CompanionIdle = 12
    CompanionExit = 13
    Lifting = 14
    PuttingDown = 15
}

$settingsDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'CorgiPetV24'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$settings = @{
    Scale = 0.60
    IdleAction = 'companion'
    RotationMinutes = 20
    Topmost = $true
    Left = $null
    Top = $null
}

try {
    if (Test-Path -LiteralPath $settingsPath) {
        $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($null -ne $saved.Scale) { $settings.Scale = [Math]::Min(0.80, [Math]::Max(0.40, [double]$saved.Scale)) }
        if ($saved.IdleAction -in @('companion', 'sleep', 'gaze', 'automatic')) { $settings.IdleAction = [string]$saved.IdleAction }
        if ($null -ne $saved.RotationMinutes) { $settings.RotationMinutes = [Math]::Min(60, [Math]::Max(1, [int]$saved.RotationMinutes)) }
        if ($null -ne $saved.Topmost) { $settings.Topmost = [bool]$saved.Topmost }
        if ($null -ne $saved.Left) { $settings.Left = [double]$saved.Left }
        if ($null -ne $saved.Top) { $settings.Top = [double]$saved.Top }
    }
}
catch {
}

$bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
$bitmap.BeginInit()
$bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$bitmap.UriSource = [System.Uri]::new($atlasPath, [System.UriKind]::Absolute)
$bitmap.EndInit()
$bitmap.Freeze()

if ($bitmap.PixelWidth -ne ($cellWidth * $columns) -or ($bitmap.PixelHeight % $cellHeight) -ne 0) {
    [System.Windows.MessageBox]::Show('动画图集尺寸不正确。', '柯基小小') | Out-Null
    exit 1
}

$window = New-Object System.Windows.Window
$window.Title = '柯基小小'
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = [bool]$settings.Topmost
$window.ShowInTaskbar = $false
$window.Width = $cellWidth * [double]$settings.Scale
$window.Height = $cellHeight * [double]$settings.Scale
$window.SnapsToDevicePixels = $true
$window.ToolTip = '左键点击互动｜按住左键拖动｜右键打开菜单'

$image = New-Object System.Windows.Controls.Image
$image.Stretch = [System.Windows.Media.Stretch]::Uniform
$image.SnapsToDevicePixels = $true
$image.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
$flipTransform = [System.Windows.Media.ScaleTransform]::new(1.0, 1.0)
$image.RenderTransform = $flipTransform
[System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::HighQuality)
$window.Content = $image

$workArea = [System.Windows.SystemParameters]::WorkArea
if ($null -ne $settings.Left -and $null -ne $settings.Top) {
    $window.Left = [double]$settings.Left
    $window.Top = [double]$settings.Top
}
else {
    $window.Left = [Math]::Max($workArea.Left, $workArea.Right - $window.Width - 28)
    $window.Top = [Math]::Max($workArea.Top, $workArea.Bottom - $window.Height - 36)
}

$script:frameCache = @{}
$script:visibleBoundsCache = @{}
$script:currentVisibleBounds = $null
$script:state = 'companion'
$script:currentAction = 'companion'
$script:actionBeforeDrag = $null
$script:idleAction = [string]$settings.IdleAction
$script:appliedIdleAction = [string]$settings.IdleAction
$script:idleSelectionMode = $null
$script:idleSelectionAt = [DateTime]::MaxValue
$script:rotationMinutes = [int]$settings.RotationMinutes
$script:autoIdleIndex = 0
$script:autoRotateAt = [DateTime]::MaxValue
$script:animationRow = $rows.CompanionIdle
$script:animationFrames = [int[]]@(0)
$script:framePosition = 0
$script:completedLoops = 0
$script:requestedLoops = -1
$script:frameIntervalMs = 1000
$script:nextFrameAt = [DateTime]::UtcNow
$script:animationCompletion = $null
$script:facesLeft = $false
$script:companionReady = $false
$script:nextCompanionMicroAt = [DateTime]::MaxValue
$script:sleepAt = [DateTime]::MaxValue
$script:gazeUntil = [DateTime]::MinValue
$script:gazeFrame = -1
$script:walkUntil = [DateTime]::MinValue
$script:walkTarget = [System.Windows.Point]::new(0, 0)
$script:walkVelocity = [System.Windows.Vector]::new(28, 0)
$script:walkMode = 'running'
$script:nextWalkTurnAt = [DateTime]::MinValue
$script:lastTickAt = [DateTime]::UtcNow
$script:isClosing = $false
$script:dragStartCursor = [System.Windows.Point]::new(0, 0)
$script:dragStartWindow = [System.Windows.Point]::new(0, 0)
$script:isPointerDown = $false
$script:isDragging = $false
$script:dragChangedInteraction = $false
$script:dragShouldLift = $false
$script:userScale = [double]$settings.Scale
$script:temporaryScale = 1.0

function Get-PetFrame {
    param([int]$Row, [int]$Column)

    $key = "$Row`:$Column"
    if (-not $script:frameCache.ContainsKey($key)) {
        $rect = [System.Windows.Int32Rect]::new(
            ($Column * $cellWidth),
            ($Row * $cellHeight),
            $cellWidth,
            $cellHeight
        )
        $crop = [System.Windows.Media.Imaging.CroppedBitmap]::new($bitmap, $rect)
        $crop.Freeze()
        $script:frameCache[$key] = $crop

        $bytesPerPixel = [int][Math]::Ceiling($crop.Format.BitsPerPixel / 8.0)
        if ($bytesPerPixel -ge 4) {
            $stride = $crop.PixelWidth * $bytesPerPixel
            $pixels = New-Object byte[] ($stride * $crop.PixelHeight)
            $crop.CopyPixels($pixels, $stride, 0)
            $minimumX = $crop.PixelWidth
            $maximumX = -1
            $minimumY = $crop.PixelHeight
            $maximumY = -1
            for ($y = 0; $y -lt $crop.PixelHeight; $y++) {
                for ($x = 0; $x -lt $crop.PixelWidth; $x++) {
                    if ($pixels[($y * $stride) + ($x * $bytesPerPixel) + 3] -le 12) { continue }
                    $minimumX = [Math]::Min($minimumX, $x)
                    $maximumX = [Math]::Max($maximumX, $x)
                    $minimumY = [Math]::Min($minimumY, $y)
                    $maximumY = [Math]::Max($maximumY, $y)
                }
            }
            if ($maximumX -ge $minimumX -and $maximumY -ge $minimumY) {
                $script:visibleBoundsCache[$key] = [int[]]@($minimumX, $maximumX, $minimumY, $maximumY)
            }
        }
    }
    return $script:frameCache[$key]
}

function Show-Frame {
    param([int]$Row, [int]$Column)
    $key = "$Row`:$Column"
    $image.Source = Get-PetFrame -Row $Row -Column $Column
    $script:currentVisibleBounds = if ($script:visibleBoundsCache.ContainsKey($key)) { $script:visibleBoundsCache[$key] } else { $null }
}

function Set-FacingLeft {
    param([bool]$FacingLeft)
    $script:facesLeft = $FacingLeft
    $flipTransform.ScaleX = if ($FacingLeft) { -1.0 } else { 1.0 }
}

function Show-CurrentFrame {
    $column = $script:animationFrames[[Math]::Min($script:framePosition, $script:animationFrames.Count - 1)]
    Show-Frame -Row $script:animationRow -Column $column
}

function Set-Animation {
    param(
        [int]$Row,
        [int[]]$Frames,
        [int]$IntervalMs,
        [int]$Loops = -1,
        [scriptblock]$Completion = $null
    )

    $script:animationRow = $Row
    $script:animationFrames = $Frames
    $script:framePosition = 0
    $script:completedLoops = 0
    $script:requestedLoops = $Loops
    $script:frameIntervalMs = $IntervalMs
    $script:animationCompletion = $Completion
    $script:nextFrameAt = [DateTime]::UtcNow.AddMilliseconds($IntervalMs)
    Show-CurrentFrame
}

function Advance-Animation {
    if ($script:animationFrames.Count -le 1) { return }
    $now = [DateTime]::UtcNow
    if ($now -lt $script:nextFrameAt) { return }

    $script:nextFrameAt = $now.AddMilliseconds($script:frameIntervalMs)
    $script:framePosition++
    if ($script:framePosition -ge $script:animationFrames.Count) {
        $script:framePosition = 0
        $script:completedLoops++
        if ($script:requestedLoops -gt 0 -and $script:completedLoops -ge $script:requestedLoops) {
            $completion = $script:animationCompletion
            $script:animationCompletion = $null
            if ($null -ne $completion) { & $completion }
            return
        }
    }
    Show-CurrentFrame
}

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $settingsDirectory)) {
            New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
        }
        [ordered]@{
            Scale = [Math]::Round($script:userScale, 2)
            IdleAction = $script:idleAction
            RotationMinutes = $script:rotationMinutes
            Topmost = $window.Topmost
            Left = [Math]::Round($window.Left, 2)
            Top = [Math]::Round($window.Top, 2)
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    }
    catch {
    }
}

function Clamp-ToDesktop {
    $area = [System.Windows.SystemParameters]::WorkArea
    if ($window.Left -lt $area.Left) { $window.Left = $area.Left }
    if ($window.Top -lt $area.Top) { $window.Top = $area.Top }
    if (($window.Left + $window.Width) -gt $area.Right) { $window.Left = $area.Right - $window.Width }
    if (($window.Top + $window.Height) -gt $area.Bottom) { $window.Top = $area.Bottom - $window.Height }
}

function Set-TemporaryScale {
    param([double]$Multiplier, [switch]$AnchorTop)

    if ([Math]::Abs($script:temporaryScale - $Multiplier) -lt 0.001) { return }
    $oldCenterX = $window.Left + ($window.Width / 2)
    $oldTop = $window.Top
    $oldBottom = $window.Top + $window.Height
    $script:temporaryScale = $Multiplier
    $window.Width = $cellWidth * $script:userScale * $script:temporaryScale
    $window.Height = $cellHeight * $script:userScale * $script:temporaryScale
    $window.Left = $oldCenterX - ($window.Width / 2)
    $window.Top = if ($AnchorTop) { $oldTop } else { $oldBottom - $window.Height }
    Clamp-ToDesktop
}

function Reset-SleepDeadline {
    if ($script:state -eq 'companion' -and $script:appliedIdleAction -eq 'sleep') {
        $script:sleepAt = [DateTime]::UtcNow.AddSeconds(30)
    }
    else {
        $script:sleepAt = [DateTime]::MaxValue
    }
}

function Stop-SpecialModes {
    $script:gazeUntil = [DateTime]::MinValue
    $script:gazeFrame = -1
    $script:walkUntil = [DateTime]::MinValue
    Set-TemporaryScale -Multiplier 1.0
}

function Start-CompanionIdle {
    if ($script:state -ne 'companion') { return }
    $script:companionReady = $true
    Set-FacingLeft $false
    Set-Animation -Row $rows.CompanionIdle -Frames ([int[]]@(0)) -IntervalMs 1000
    $script:nextCompanionMicroAt = [DateTime]::UtcNow.AddSeconds(2)
}

function Start-Companion {
    if ($script:state -eq 'companion') {
        Reset-SleepDeadline
        return
    }

    Stop-SpecialModes
    $script:state = 'companion'
    $script:currentAction = 'companion'
    $script:companionReady = $false
    Set-FacingLeft $false
    Reset-SleepDeadline
    Set-Animation -Row $rows.CompanionEntry -Frames ([int[]](0..5)) -IntervalMs 160 -Loops 1 -Completion { Start-CompanionIdle }
}

function Play-CompanionMicroAction {
    if ($script:state -ne 'companion' -or -not $script:companionReady) { return }
    $script:companionReady = $false
    $sequences = @(
        [int[]]@(0, 1, 2),
        [int[]]@(2, 3, 4),
        [int[]]@(4, 5, 4),
        [int[]]@(4, 6, 4),
        [int[]]@(0, 7, 0)
    )
    $frames = $sequences[(Get-Random -Minimum 0 -Maximum $sequences.Count)]
    Set-Animation -Row $rows.CompanionIdle -Frames $frames -IntervalMs 140 -Loops 1 -Completion { Start-CompanionIdle }
}

function Start-Sleep {
    if ($script:state -eq 'sleep') { return }

    Stop-SpecialModes
    $script:state = 'sleep'
    $script:currentAction = 'sleep'
    $script:companionReady = $false
    $script:sleepAt = [DateTime]::MaxValue
    Set-FacingLeft $false
    Set-Animation -Row $rows.SleepEntrySecond -Frames ([int[]](0..7)) -IntervalMs 140 -Loops 1 -Completion {
        if ($script:state -ne 'sleep') { return }
        Set-Animation -Row $rows.SleepIdle -Frames ([int[]]@(0, 1)) -IntervalMs 140 -Loops 1 -Completion {
            if ($script:state -eq 'sleep') {
                Set-Animation -Row $rows.SleepIdle -Frames ([int[]]@(1, 2, 3, 4)) -IntervalMs 520
            }
        }
    }
}

function Start-InteractionAnimation {
    param([string]$Action, [int]$Row, [int[]]$Frames, [int]$IntervalMs, [int]$Loops)

    Stop-SpecialModes
    $script:state = 'interaction'
    $script:currentAction = $Action
    $script:companionReady = $false
    $script:sleepAt = [DateTime]::MaxValue
    $script:autoRotateAt = [DateTime]::MaxValue
    Set-FacingLeft $false
    Set-Animation -Row $Row -Frames $Frames -IntervalMs $IntervalMs -Loops $Loops -Completion { Finish-Interaction }
}

function Start-Dance {
    Stop-SpecialModes
    $script:state = 'interaction'
    $script:currentAction = 'dance'
    $script:companionReady = $false
    $script:sleepAt = [DateTime]::MaxValue
    $script:autoRotateAt = [DateTime]::MaxValue
    Set-FacingLeft $false
    Set-TemporaryScale -Multiplier 1.3
    Set-Animation -Row $rows.Dance -Frames ([int[]](0..7)) -IntervalMs 125 -Loops 2 -Completion {
        if ($script:state -ne 'interaction' -or $script:currentAction -ne 'dance') { return }
        Set-FacingLeft $true
        Set-Animation -Row $rows.Dance -Frames ([int[]](0..7)) -IntervalMs 125 -Loops 2 -Completion {
            if ($script:state -ne 'interaction' -or $script:currentAction -ne 'dance') { return }
            Set-FacingLeft $false
            Set-TemporaryScale -Multiplier 1.0
            Finish-Interaction
        }
    }
}
function Start-Petting { Start-InteractionAnimation -Action 'petting' -Row $rows.Petting -Frames ([int[]](0..5)) -IntervalMs 200 -Loops 2 }
function Start-Roll { Start-InteractionAnimation -Action 'roll' -Row $rows.Roll -Frames ([int[]](0..7)) -IntervalMs 150 -Loops 1 }
function Start-Spin { Start-InteractionAnimation -Action 'spin' -Row $rows.Spin -Frames ([int[]](0..7)) -IntervalMs 125 -Loops 2 }
function Start-Jump { Start-InteractionAnimation -Action 'jumping' -Row $rows.Jump -Frames ([int[]](0..4)) -IntervalMs 160 -Loops 3 }

function Start-Gaze {
    if ($script:state -eq 'gaze') { return }
    Stop-SpecialModes
    $script:state = 'gaze'
    $script:currentAction = 'gaze'
    $script:companionReady = $false
    $script:sleepAt = [DateTime]::MaxValue
    Set-FacingLeft $false
    $script:gazeUntil = [DateTime]::MaxValue
    $script:gazeFrame = -1
}

function Get-CursorPositionDip {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $point = [System.Windows.Point]::new([double]$cursor.X, [double]$cursor.Y)
    $source = [System.Windows.PresentationSource]::FromVisual($window)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        return $source.CompositionTarget.TransformFromDevice.Transform($point)
    }
    return $point
}

function Test-LiftStartPoint {
    param([System.Windows.Point]$Point)

    $source = $image.Source
    $visibleBounds = $script:currentVisibleBounds
    if ($null -eq $source -or $source.PixelWidth -le 0 -or $source.PixelHeight -le 0 -or $null -eq $visibleBounds) {
        return ($Point.Y -le ($window.Height * 0.35))
    }
    $minimumX = $visibleBounds[0]
    $maximumX = $visibleBounds[1]
    $minimumY = $visibleBounds[2]
    $maximumY = $visibleBounds[3]
    if ($script:facesLeft) {
        $mirroredMinimumX = $source.PixelWidth - $maximumX - 1
        $maximumX = $source.PixelWidth - $minimumX - 1
        $minimumX = $mirroredMinimumX
    }

    $actualWidth = if ($image.ActualWidth -gt 0) { $image.ActualWidth } else { $window.Width }
    $actualHeight = if ($image.ActualHeight -gt 0) { $image.ActualHeight } else { $window.Height }
    $scale = [Math]::Min($actualWidth / $source.PixelWidth, $actualHeight / $source.PixelHeight)
    $drawnWidth = $source.PixelWidth * $scale
    $drawnHeight = $source.PixelHeight * $scale
    $drawnLeft = ($actualWidth - $drawnWidth) / 2
    $drawnTop = ($actualHeight - $drawnHeight) / 2
    $visibleLeft = $drawnLeft + ($minimumX * $scale)
    $visibleTop = $drawnTop + ($minimumY * $scale)
    $visibleRight = $drawnLeft + (($maximumX + 1) * $scale)
    $visibleBottom = $drawnTop + (($maximumY + 1) * $scale)
    $topThreshold = $visibleTop + (($visibleBottom - $visibleTop) * 0.35)
    return ($Point.X -ge $visibleLeft -and $Point.X -le $visibleRight -and $Point.Y -ge $visibleTop -and $Point.Y -le $topThreshold)
}

function Start-Lift {
    param([System.Windows.Point]$MouseLocation)

    $script:actionBeforeDrag = $script:currentAction
    Stop-SpecialModes
    $script:state = 'dragLift'
    $script:companionReady = $false
    $script:sleepAt = [DateTime]::MaxValue
    $script:autoRotateAt = [DateTime]::MaxValue
    Set-FacingLeft $false
    Set-TemporaryScale -Multiplier 1.5 -AnchorTop
    Set-Animation -Row $rows.Lifting -Frames ([int[]](0..7)) -IntervalMs 90 -Loops 1 -Completion {
        if ($script:state -eq 'dragLift') {
            Set-Animation -Row $rows.Lifting -Frames ([int[]](4..7)) -IntervalMs 160
        }
    }
    $liftScale = $script:userScale * $script:temporaryScale
    $window.Left = $MouseLocation.X - (($cellWidth / 2) * $liftScale)
    $window.Top = $MouseLocation.Y - (2 * $liftScale)
}

function Restore-ActionBeforeDrag {
    $action = $script:actionBeforeDrag
    $script:actionBeforeDrag = $null
    switch ($action) {
        'companion' { Start-Companion; if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation } }
        'sleep' { Start-Sleep; if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation } }
        'gaze' { Start-Gaze; if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation } }
        'dance' { Start-Dance }
        'petting' { Start-Petting }
        'roll' { Start-Roll }
        'spin' { Start-Spin }
        'running' { Start-Walk -Mode 'running' }
        'jumping' { Start-Walk -Mode 'jumping' }
        default { Apply-IdleAction -Mode $script:appliedIdleAction }
    }
}

function Start-PutDown {
    if ($script:state -ne 'dragLift') { return }
    $script:state = 'dragDrop'
    Set-FacingLeft $false
    Set-Animation -Row $rows.PuttingDown -Frames ([int[]](0..7)) -IntervalMs 90 -Loops 1 -Completion {
        Set-TemporaryScale -Multiplier 1.0
        Restore-ActionBeforeDrag
    }
}

function Update-Gaze {
    if ($script:state -ne 'gaze' -or $script:gazeUntil -eq [DateTime]::MinValue) { return }

    $mouse = Get-CursorPositionDip
    $centerX = $window.Left + ($window.Width / 2)
    $centerY = $window.Top + ($window.Height / 2)
    $deltaX = $mouse.X - $centerX
    $deltaY = $centerY - $mouse.Y
    $degrees = [Math]::Atan2($deltaX, $deltaY) * 180.0 / [Math]::PI
    if ($degrees -lt 0) { $degrees += 360.0 }
    $frame = [int]([Math]::Round($degrees / 22.5)) % 16
    if ($frame -eq $script:gazeFrame) { return }

    $script:gazeFrame = $frame
    if ($frame -lt 8) {
        Show-Frame -Row $rows.GazeFirstHalf -Column $frame
    }
    else {
        Show-Frame -Row $rows.GazeSecondHalf -Column ($frame - 8)
    }
}

function Choose-WalkTarget {
    $area = [System.Windows.SystemParameters]::WorkArea
    $minimumX = $area.Left
    $maximumX = [Math]::Max($minimumX, $area.Right - $window.Width)
    $minimumY = $area.Top
    $maximumY = [Math]::Max($minimumY, $area.Bottom - $window.Height)
    $script:walkTarget = [System.Windows.Point]::new(
        (Get-Random -Minimum ([int]$minimumX) -Maximum ([int]([Math]::Max($minimumX + 1, $maximumX + 1)))),
        (Get-Random -Minimum ([int]$minimumY) -Maximum ([int]([Math]::Max($minimumY + 1, $maximumY + 1))))
    )
    $script:nextWalkTurnAt = [DateTime]::UtcNow.AddSeconds((Get-Random -Minimum 8 -Maximum 31) / 10.0)
}

function Start-Walk {
    param([string]$Mode = '')

    Stop-SpecialModes
    $script:state = 'interaction'
    $script:companionReady = $false
    $script:sleepAt = [DateTime]::MaxValue
    $script:autoRotateAt = [DateTime]::MaxValue
    $script:walkMode = if ($Mode -in @('running', 'jumping')) { $Mode } elseif ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { 'running' } else { 'jumping' }
    $script:currentAction = $script:walkMode
    $script:walkUntil = [DateTime]::UtcNow.AddSeconds(30)
    Choose-WalkTarget
    if ($script:walkMode -eq 'running') {
        Set-TemporaryScale -Multiplier 1.3
        Set-Animation -Row $rows.RunningRight -Frames ([int[]](0..7)) -IntervalMs 110
    }
    else {
        Set-Animation -Row $rows.Jump -Frames ([int[]](0..4)) -IntervalMs 140
    }
}

function Update-Walk {
    param([double]$ElapsedSeconds)
    if ($script:state -ne 'interaction' -or $script:walkUntil -eq [DateTime]::MinValue) { return }
    if ([DateTime]::UtcNow -ge $script:walkUntil) {
        Save-Settings
        Finish-Interaction
        return
    }

    $dx = $script:walkTarget.X - $window.Left
    $dy = $script:walkTarget.Y - $window.Top
    $distance = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
    if ($distance -lt 36 -or [DateTime]::UtcNow -ge $script:nextWalkTurnAt) {
        Choose-WalkTarget
        $dx = $script:walkTarget.X - $window.Left
        $dy = $script:walkTarget.Y - $window.Top
        $distance = [Math]::Max(1.0, [Math]::Sqrt(($dx * $dx) + ($dy * $dy)))
    }

    $speed = if ($script:walkMode -eq 'running') { 85.0 } else { 150.0 }
    $desiredX = ($dx / [Math]::Max(1.0, $distance)) * $speed
    $desiredY = ($dy / [Math]::Max(1.0, $distance)) * $speed
    $steering = 0.14
    $script:walkVelocity = [System.Windows.Vector]::new(
        ($script:walkVelocity.X + (($desiredX - $script:walkVelocity.X) * $steering)),
        ($script:walkVelocity.Y + (($desiredY - $script:walkVelocity.Y) * $steering))
    )
    $velocityLength = [Math]::Max(1.0, $script:walkVelocity.Length)
    $script:walkVelocity = [System.Windows.Vector]::new(
        ($script:walkVelocity.X / $velocityLength * $speed),
        ($script:walkVelocity.Y / $velocityLength * $speed)
    )
    $window.Left += $script:walkVelocity.X * $ElapsedSeconds
    $window.Top += $script:walkVelocity.Y * $ElapsedSeconds
    Set-FacingLeft ($script:walkVelocity.X -lt 0)
    Clamp-ToDesktop
}

function Start-RandomInteraction {
    switch (Get-Random -Minimum 0 -Maximum 5) {
        0 { Start-Dance }
        1 { Start-Petting }
        2 { Start-Roll }
        3 { Start-Spin }
        default { Start-Walk }
    }
}

function Schedule-AutomaticRotation {
    if ($script:appliedIdleAction -eq 'automatic') {
        $script:autoRotateAt = [DateTime]::UtcNow.AddMinutes($script:rotationMinutes)
    }
    else {
        $script:autoRotateAt = [DateTime]::MaxValue
    }
}

function Advance-AutomaticIdle {
    if ($script:appliedIdleAction -ne 'automatic') { return }
    $script:autoIdleIndex = ($script:autoIdleIndex + 1) % 3
    switch ($script:autoIdleIndex) {
        0 { Start-Companion }
        1 { Start-Gaze }
        default { Start-Sleep }
    }
    Schedule-AutomaticRotation
}

function Finish-Interaction {
    Set-TemporaryScale -Multiplier 1.0
    switch ($script:appliedIdleAction) {
        'gaze' { Start-Gaze }
        'automatic' {
            $script:autoIdleIndex = 0
            Start-Companion
            Schedule-AutomaticRotation
        }
        default { Start-Companion }
    }
}

function Update-IdleMenuChecks {
    $companionIdleItem.IsChecked = ($script:idleAction -eq 'companion')
    $sleepIdleItem.IsChecked = ($script:idleAction -eq 'sleep')
    $gazeIdleItem.IsChecked = ($script:idleAction -eq 'gaze')
    $automaticIdleItem.IsChecked = ($script:idleAction -eq 'automatic')
}

function Test-CurrentIdleAction {
    param([string]$Mode)
    switch ($Mode) {
        'companion' { return ($script:state -eq 'companion') }
        'sleep' { return ($script:state -eq 'sleep') }
        'gaze' { return ($script:state -eq 'gaze') }
        'automatic' { return ($script:appliedIdleAction -eq 'automatic' -and $script:state -in @('companion', 'sleep', 'gaze')) }
    }
    return $false
}

function Apply-IdleAction {
    param([string]$Mode)
    switch ($Mode) {
        'companion' { Start-Companion }
        'sleep' { Start-Sleep }
        'gaze' { Start-Gaze }
        'automatic' {
            $script:autoIdleIndex = 0
            Start-Companion
            Schedule-AutomaticRotation
        }
    }
}

function Select-IdleAction {
    param([string]$Mode, [bool]$ShouldSave = $true)

    $script:idleAction = $Mode
    $script:autoRotateAt = [DateTime]::MaxValue
    $script:sleepAt = [DateTime]::MaxValue
    $script:idleSelectionMode = $null
    $script:idleSelectionAt = [DateTime]::MaxValue
    if (Test-CurrentIdleAction -Mode $Mode) {
        $script:appliedIdleAction = $Mode
        if ($Mode -eq 'automatic') { Schedule-AutomaticRotation }
    }
    else {
        $script:idleSelectionMode = $Mode
        $script:idleSelectionAt = [DateTime]::UtcNow.AddSeconds(30)
    }
    Update-IdleMenuChecks
    if ($ShouldSave) { Save-Settings }
}

function Set-PetScale {
    param([double]$Scale)
    $script:userScale = [Math]::Min(0.80, [Math]::Max(0.40, $Scale))
    $window.Width = $cellWidth * $script:userScale * $script:temporaryScale
    $window.Height = $cellHeight * $script:userScale * $script:temporaryScale
    Clamp-ToDesktop
    Save-Settings
}

function New-PetMenuItem {
    param([string]$Header, [scriptblock]$Action)
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $Header
    $item.Add_Click($Action)
    return $item
}

$menu = New-Object System.Windows.Controls.ContextMenu
$menu.Items.Add((New-PetMenuItem '陪伴' { Start-Companion; if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation } })) | Out-Null
$menu.Items.Add((New-PetMenuItem '睡觉' { Start-Sleep; if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation } })) | Out-Null
$menu.Items.Add((New-PetMenuItem '注视' { Start-Gaze; if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation } })) | Out-Null
$menu.Items.Add((New-PetMenuItem '散步' { Start-Walk })) | Out-Null
$menu.Items.Add((New-PetMenuItem '扭屁股' { Start-Dance })) | Out-Null

$optimizationMenu = New-Object System.Windows.Controls.MenuItem
$optimizationMenu.Header = '待优化'
$optimizationMenu.Items.Add((New-PetMenuItem '摸摸' { Start-Petting })) | Out-Null
$optimizationMenu.Items.Add((New-PetMenuItem '连贯打滚' { Start-Roll })) | Out-Null
$optimizationMenu.Items.Add((New-PetMenuItem '芭蕾旋转' { Start-Spin })) | Out-Null
$menu.Items.Add($optimizationMenu) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$sizeMenu = New-Object System.Windows.Controls.MenuItem
$sizeMenu.Header = '大小'
$sizeMenu.Items.Add((New-PetMenuItem '40%' { Set-PetScale 0.40 })) | Out-Null
$sizeMenu.Items.Add((New-PetMenuItem '50%' { Set-PetScale 0.50 })) | Out-Null
$sizeMenu.Items.Add((New-PetMenuItem '60%' { Set-PetScale 0.60 })) | Out-Null
$sizeMenu.Items.Add((New-PetMenuItem '70%' { Set-PetScale 0.70 })) | Out-Null
$sizeMenu.Items.Add((New-PetMenuItem '80%' { Set-PetScale 0.80 })) | Out-Null
$menu.Items.Add($sizeMenu) | Out-Null

$idleMenu = New-Object System.Windows.Controls.MenuItem
$idleMenu.Header = '静置动作'
$companionIdleItem = New-Object System.Windows.Controls.MenuItem
$companionIdleItem.Header = '陪伴'
$companionIdleItem.IsCheckable = $true
$sleepIdleItem = New-Object System.Windows.Controls.MenuItem
$sleepIdleItem.Header = '睡觉'
$sleepIdleItem.IsCheckable = $true
$gazeIdleItem = New-Object System.Windows.Controls.MenuItem
$gazeIdleItem.Header = '注视'
$gazeIdleItem.IsCheckable = $true
$automaticIdleItem = New-Object System.Windows.Controls.MenuItem
$automaticIdleItem.Header = '自动轮替'
$automaticIdleItem.IsCheckable = $true
$companionIdleItem.IsChecked = ($script:idleAction -eq 'companion')
$sleepIdleItem.IsChecked = ($script:idleAction -eq 'sleep')
$gazeIdleItem.IsChecked = ($script:idleAction -eq 'gaze')
$automaticIdleItem.IsChecked = ($script:idleAction -eq 'automatic')
$companionIdleItem.Add_Click({ Select-IdleAction -Mode 'companion' })
$sleepIdleItem.Add_Click({ Select-IdleAction -Mode 'sleep' })
$gazeIdleItem.Add_Click({ Select-IdleAction -Mode 'gaze' })
$automaticIdleItem.Add_Click({ Select-IdleAction -Mode 'automatic' })
$idleMenu.Items.Add($companionIdleItem) | Out-Null
$idleMenu.Items.Add($sleepIdleItem) | Out-Null
$idleMenu.Items.Add($gazeIdleItem) | Out-Null
$idleMenu.Items.Add($automaticIdleItem) | Out-Null
$idleMenu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$rotationControlItem = New-Object System.Windows.Controls.MenuItem
$rotationControlItem.StaysOpenOnClick = $true
$rotationPanel = New-Object System.Windows.Controls.StackPanel
$rotationPanel.Orientation = [System.Windows.Controls.Orientation]::Vertical
$rotationPanel.Width = 220
$rotationLabel = New-Object System.Windows.Controls.TextBlock
$rotationLabel.Text = "轮替时间：$($script:rotationMinutes)分钟"
$rotationLabel.Margin = [System.Windows.Thickness]::new(4, 2, 4, 0)
$rotationSlider = New-Object System.Windows.Controls.Slider
$rotationSlider.Minimum = 1
$rotationSlider.Maximum = 60
$rotationSlider.Value = $script:rotationMinutes
$rotationSlider.TickFrequency = 1
$rotationSlider.IsSnapToTickEnabled = $true
$rotationSlider.Width = 210
$rotationSlider.Margin = [System.Windows.Thickness]::new(4, 0, 4, 2)
$rotationSlider.Add_ValueChanged({
    $minutes = [Math]::Min(60, [Math]::Max(1, [int][Math]::Round($rotationSlider.Value)))
    $script:rotationMinutes = $minutes
    $rotationLabel.Text = "轮替时间：$($minutes)分钟"
    if ($script:appliedIdleAction -eq 'automatic') { Schedule-AutomaticRotation }
    Save-Settings
})
$rotationPanel.Children.Add($rotationLabel) | Out-Null
$rotationPanel.Children.Add($rotationSlider) | Out-Null
$rotationControlItem.Header = $rotationPanel
$idleMenu.Items.Add($rotationControlItem) | Out-Null
$menu.Items.Add($idleMenu) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$topItem = New-Object System.Windows.Controls.MenuItem
$topItem.Header = '始终置顶'
$topItem.IsCheckable = $true
$topItem.IsChecked = $window.Topmost
$topItem.Add_Click({
    $window.Topmost = $topItem.IsChecked
    Save-Settings
})
$menu.Items.Add($topItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add((New-PetMenuItem '退出柯基小小' { $window.Close() })) | Out-Null
$window.ContextMenu = $menu

$window.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $script:isPointerDown = $true
    $script:isDragging = $false
    $script:dragChangedInteraction = $false
    $script:dragShouldLift = Test-LiftStartPoint -Point ($eventArgs.GetPosition($image))
    $script:dragStartCursor = Get-CursorPositionDip
    $script:dragStartWindow = [System.Windows.Point]::new($window.Left, $window.Top)
    [System.Windows.Input.Mouse]::Capture($window) | Out-Null
    $eventArgs.Handled = $true
})

$window.Add_MouseMove({
    if (-not $script:isPointerDown -or [System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    $cursor = Get-CursorPositionDip
    $deltaX = $cursor.X - $script:dragStartCursor.X
    $deltaY = $cursor.Y - $script:dragStartCursor.Y
    if (-not $script:isDragging -and ([Math]::Abs($deltaX) -ge 3 -or [Math]::Abs($deltaY) -ge 3)) {
        $script:isDragging = $true
        if ($script:dragShouldLift) {
            Start-Lift -MouseLocation $cursor
            $script:dragStartCursor = $cursor
            $script:dragStartWindow = [System.Windows.Point]::new($window.Left, $window.Top)
            $deltaX = 0
            $deltaY = 0
        }
    }
    if ($script:isDragging) {
        $window.Left = $script:dragStartWindow.X + $deltaX
        $window.Top = $script:dragStartWindow.Y + $deltaY
        Clamp-ToDesktop
    }
})

$window.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    if (-not $script:isPointerDown) { return }
    $script:isPointerDown = $false
    [System.Windows.Input.Mouse]::Capture($null) | Out-Null

    if ($script:isDragging) {
        Save-Settings
        if ($script:state -eq 'dragLift') {
            Start-PutDown
        }
        elseif ($script:state -eq 'companion') {
            Reset-SleepDeadline
        }
    }
    else {
        if ($script:state -eq 'sleep') {
            Start-Companion
            if ($script:appliedIdleAction -eq 'automatic') {
                $script:autoIdleIndex = 0
                Schedule-AutomaticRotation
            }
        }
        elseif ($script:state -in @('companion', 'gaze')) {
            Start-RandomInteraction
        }
    }
    $eventArgs.Handled = $true
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
    if ($script:isClosing) { return }
    $now = [DateTime]::UtcNow
    $elapsed = [Math]::Min(0.10, [Math]::Max(0.0, ($now - $script:lastTickAt).TotalSeconds))
    $script:lastTickAt = $now

    if ($null -ne $script:idleSelectionMode -and $now -ge $script:idleSelectionAt) {
        $pendingMode = $script:idleSelectionMode
        $script:idleSelectionMode = $null
        $script:idleSelectionAt = [DateTime]::MaxValue
        $script:appliedIdleAction = $pendingMode
        if ($script:state -notin @('dragLift', 'dragDrop') -and $script:walkUntil -eq [DateTime]::MinValue) {
            Apply-IdleAction -Mode $pendingMode
        }
    }

    if ($script:appliedIdleAction -eq 'automatic' -and $now -ge $script:autoRotateAt) {
        Advance-AutomaticIdle
    }

    if ($script:state -eq 'companion') {
        if ($script:appliedIdleAction -eq 'sleep' -and $now -ge $script:sleepAt) {
            Start-Sleep
        }
        elseif ($script:companionReady -and $now -ge $script:nextCompanionMicroAt) {
            Play-CompanionMicroAction
        }
    }

    if ($script:state -eq 'gaze') {
        Update-Gaze
    }
    elseif ($script:walkUntil -ne [DateTime]::MinValue) {
        Update-Walk -ElapsedSeconds $elapsed
        Advance-Animation
    }
    else {
        Advance-Animation
    }
})

$window.Add_Loaded({ Clamp-ToDesktop })
$window.Add_Closing({
    $script:isClosing = $true
    $timer.Stop()
    Save-Settings
})

# Fresh installs default to companion; saved idle choices are restored.
$script:state = 'launching'
Start-Companion
switch ($script:appliedIdleAction) {
    'sleep' { Reset-SleepDeadline }
    'gaze' { Start-Gaze }
    'automatic' {
        $script:autoIdleIndex = 0
        Schedule-AutomaticRotation
    }
}
$timer.Start()

try {
    $null = $window.ShowDialog()
}
finally {
    $timer.Stop()
    if ($createdNew) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}
