# Shell.ps1 - unified accordion window: XAML, theme application, animated section
# toggle, and per-section render functions. The single window for the unified overlay.
#
# Consumes (speculative - defined by other legs / Claude modules):
#   $script:Themes (Leg F), $script:State/$script:Stats/$script:BarTrackWidth/$script:WarnPct/
#   $script:CritPct + Fmt-Tok/Fmt-Money/Format-Reset/NewBrush/New-GradientBrush/New-GradientBrush2
#   (Claude modules), $script:CodexStats (Leg A), $script:LiveData/$script:LocalData/
#   $script:SummaryData/$script:AuthState/$script:CursorErrMsg/$script:CursorLastFetch/Fmt-Num
#   (Leg B), $script:window/Save-UnifiedState (Leg E).

# ---------------------------------------------------------------------------
# XAML - merged accordion window (Claude / Codex / Cursor sections)
# Every x:Name is globally unique: Claude keeps its Ui.ps1 names; Codex names are
# codex*; Cursor dup names become cursor*.
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="root"
        Title="AI Usage" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="Manual" ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <Window.Resources>
    <LinearGradientBrush x:Key="Divider" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="Transparent" Offset="0"/>
      <GradientStop Color="#38BDF828" Offset="0.25"/>
      <GradientStop Color="#C084FC28" Offset="0.75"/>
      <GradientStop Color="Transparent" Offset="1"/>
    </LinearGradientBrush>

    <!-- Thin overlay scrollbar. The progress bars are a fixed 250px wide, so a
         scrollbar that took layout width would clip them; this one is drawn on
         top of the content column instead. -->
    <Style x:Key="OverlayScrollBar" TargetType="ScrollBar">
      <Setter Property="Width" Value="4"/>
      <Setter Property="Background" Value="Transparent"/>
      <!-- Negative right margin parks the bar in the panel's 14px gutter, clear
           of the 250px-wide progress tracks it would otherwise sit on top of. -->
      <Setter Property="Margin" Value="0,2,-9,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Border Background="#22000000" CornerRadius="2" Width="4">
              <Track x:Name="PART_Track" IsDirectionReversed="True" ViewportSize="NaN">
                <Track.Thumb>
                  <Thumb MinHeight="24">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#7038BDF8" CornerRadius="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <ControlTemplate x:Key="OverlayScrollViewer" TargetType="ScrollViewer">
      <Grid>
        <ScrollContentPresenter x:Name="PART_ScrollContentPresenter"/>
        <ScrollBar x:Name="PART_VerticalScrollBar" Orientation="Vertical"
                   Style="{StaticResource OverlayScrollBar}"
                   HorizontalAlignment="Right"
                   Value="{TemplateBinding VerticalOffset}"
                   Maximum="{TemplateBinding ScrollableHeight}"
                   ViewportSize="{TemplateBinding ViewportHeight}"
                   Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
      </Grid>
    </ControlTemplate>
    <StreamGeometry x:Key="IcoClock">M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M8,4.6 V8 L10.4,9.4</StreamGeometry>
    <StreamGeometry x:Key="IcoCalendar">M3,3.5 H13 A1,1 0 0 1 14,4.5 V13 A1,1 0 0 1 13,14 H3 A1,1 0 0 1 2,13 V4.5 A1,1 0 0 1 3,3.5 Z M2,7 H14 M5.2,2 V4.8 M10.8,2 V4.8</StreamGeometry>
    <StreamGeometry x:Key="IcoDatabase">M2.5,4 A5.5,2 0 1 0 13.5,4 A5.5,2 0 1 0 2.5,4 Z M2.5,4 V12 A5.5,2 0 0 0 13.5,12 V4 M2.5,8 A5.5,2 0 0 0 13.5,8</StreamGeometry>
    <StreamGeometry x:Key="IcoPerson">M10.7,5 A2.7,2.7 0 1 1 5.3,5 A2.7,2.7 0 1 1 10.7,5 Z M2.8,14 C3.3,11 5.4,9.6 8,9.6 C10.6,9.6 12.7,11 13.2,14</StreamGeometry>
    <StreamGeometry x:Key="IcoDollar">M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M10,5.9 C9.6,5.2 8.9,4.9 8,4.9 C6.9,4.9 6.1,5.5 6.1,6.35 C6.1,8.4 9.9,7.5 9.9,9.65 C9.9,10.55 9.1,11.1 8,11.1 C7,11.1 6.3,10.8 5.9,10.1 M8,3.7 V4.9 M8,11.1 V12.3</StreamGeometry>
    <StreamGeometry x:Key="IcoBars">M3,13.5 V9.5 M6.5,13.5 V5.5 M10,13.5 V8 M13.5,13.5 V3</StreamGeometry>
    <StreamGeometry x:Key="IcoMoon">M13.2,9.9 A5.6,5.6 0 1 1 6.1,2.8 A4.5,4.5 0 0 0 13.2,9.9 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoChat">M3,3 H13 A1,1 0 0 1 14,4 V10.5 A1,1 0 0 1 13,11.5 H7.2 L4.3,13.8 V11.5 H3 A1,1 0 0 1 2,10.5 V4 A1,1 0 0 1 3,3 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoRefresh">M13.3,6.2 A5.4,5.4 0 0 0 3.4,5 M3,2.2 V5.4 H6.2 M2.7,9.8 A5.4,5.4 0 0 0 12.6,11 M13,13.8 V10.6 H9.8</StreamGeometry>
    <StreamGeometry x:Key="IcoInfo">M8,1.75 A6.25,6.25 0 1 1 7.99,1.75 Z M8,7.3 V11.3 M8,4.7 V4.9</StreamGeometry>
    <StreamGeometry x:Key="IcoSliders">M2.5,4.5 H8.1 M11.9,4.5 H13.5 M11.9,4.5 A1.9,1.9 0 1 1 8.1,4.5 A1.9,1.9 0 1 1 11.9,4.5 Z M2.5,11.5 H4.1 M7.9,11.5 H13.5 M7.9,11.5 A1.9,1.9 0 1 1 4.1,11.5 A1.9,1.9 0 1 1 7.9,11.5 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoChevDown">M4.5,6.3 L8,9.8 L11.5,6.3</StreamGeometry>
    <StreamGeometry x:Key="IcoLayers">M8,2 L14,5 L8,8 L2,5 Z M2,8 L8,11 L14,8 M2,11 L8,14 L14,11</StreamGeometry>
    <StreamGeometry x:Key="IcoEye">M1.5,8 C3.2,4.8 5.5,3.5 8,3.5 C10.5,3.5 12.8,4.8 14.5,8 C12.8,11.2 10.5,12.5 8,12.5 C5.5,12.5 3.2,11.2 1.5,8 Z M10.2,8 A2.2,2.2 0 1 1 5.8,8 A2.2,2.2 0 1 1 10.2,8 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoEyeOff">M1.5,8 C3.2,4.8 5.5,3.5 8,3.5 C10.5,3.5 12.8,4.8 14.5,8 C12.8,11.2 10.5,12.5 8,12.5 C5.5,12.5 3.2,11.2 1.5,8 Z M2.5,2.5 L13.5,13.5</StreamGeometry>
    <StreamGeometry x:Key="IcoBell">M4,11 V7.2 A4,4 0 0 1 12,7.2 V11 L13.2,12.3 H2.8 Z M6.6,13.8 A1.5,1.5 0 0 0 9.4,13.8</StreamGeometry>
    <StreamGeometry x:Key="IcoBellOff">M4,11 V7.2 A4,4 0 0 1 12,7.2 V11 L13.2,12.3 H2.8 Z M6.6,13.8 A1.5,1.5 0 0 0 9.4,13.8 M2,2 L14,14</StreamGeometry>
    <StreamGeometry x:Key="IcoCopy">M5.5,5.5 H12.5 A1,1 0 0 1 13.5,6.5 V13 A1,1 0 0 1 12.5,14 H6.5 A1,1 0 0 1 5.5,13 Z M3.5,10.5 H3 A1,1 0 0 1 2,9.5 V3 A1,1 0 0 1 3,2 H9.5 A1,1 0 0 1 10.5,3 V3.5</StreamGeometry>
    <StreamGeometry x:Key="IcoTag">M2,2.5 H7.8 L14,8.7 L8.7,14 L2.5,7.8 V2.5 Z M6.2,5.4 A0.8,0.8 0 1 1 4.6,5.4 A0.8,0.8 0 1 1 6.2,5.4 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoDownload">M8,2 V10 M4.8,6.8 L8,10 L11.2,6.8 M2.5,11.5 V13.5 H13.5 V11.5</StreamGeometry>
    <StreamGeometry x:Key="IcoWindow">M3,3 H13 A1,1 0 0 1 14,4 V12 A1,1 0 0 1 13,13 H3 A1,1 0 0 1 2,12 V4 A1,1 0 0 1 3,3 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoKeyboard">M2.5,4 H13.5 A1,1 0 0 1 14.5,5 V11 A1,1 0 0 1 13.5,12 H2.5 A1,1 0 0 1 1.5,11 V5 A1,1 0 0 1 2.5,4 Z M4,6.6 H4.3 M6.5,6.6 H6.8 M9.2,6.6 H9.5 M11.7,6.6 H12 M4,8.6 H4.3 M11.7,8.6 H12 M5.8,10 H10.2</StreamGeometry>
    <StreamGeometry x:Key="IcoCorner">M2.5,6 V3.5 A1,1 0 0 1 3.5,2.5 H6 M10,2.5 H12.5 A1,1 0 0 1 13.5,3.5 V6 M13.5,10 V12.5 A1,1 0 0 1 12.5,13.5 H10 M6,13.5 H3.5 A1,1 0 0 1 2.5,12.5 V10</StreamGeometry>
    <StreamGeometry x:Key="IcoDrop">M8,2 C8,2 3.5,7 3.5,10 A4.5,4.5 0 0 0 12.5,10 C12.5,7 8,2 8,2 Z</StreamGeometry>
    <StreamGeometry x:Key="IcoPalette">M8,2 A6,6 0 1 0 8,14 C9,14 9.4,13.3 9,12.6 C8.5,11.8 9,10.8 10,10.8 H11.5 A2.5,2.5 0 0 0 14,8.3 C14,4.8 11.3,2 8,2 Z M5,7.3 H5.3 M7.2,4.9 H7.5 M10.3,5.3 H10.6</StreamGeometry>
    <StreamGeometry x:Key="IcoList">M3,3 H13 A1,1 0 0 1 14,4 V12 A1,1 0 0 1 13,13 H3 A1,1 0 0 1 2,12 V4 A1,1 0 0 1 3,3 Z M4.8,6 H11.2 M4.8,8.3 H11.2 M4.8,10.6 H9</StreamGeometry>
    <StreamGeometry x:Key="IcoTrend">M2,11.5 L6,7.5 L8.6,10.1 L14,4.6 M10.6,4.6 H14 V8</StreamGeometry>
    <StreamGeometry x:Key="IcoPower">M8,2 V7.5 M5,3.7 A5.3,5.3 0 1 0 11,3.7</StreamGeometry>
    <StreamGeometry x:Key="IcoMinus">M4,8 H12</StreamGeometry>
    <StreamGeometry x:Key="IcoExit">M9.5,2.5 H3.5 A1,1 0 0 0 2.5,3.5 V12.5 A1,1 0 0 0 3.5,13.5 H9.5 M7,8 H14 M11.5,5.5 L14,8 L11.5,10.5</StreamGeometry>
    <StreamGeometry x:Key="IcoBolt">M9,1.8 L3.5,9 H7.6 L7,14.2 L12.5,7 H8.4 Z</StreamGeometry>

    <Style x:Key="RowIcon" TargetType="Path">
      <Setter Property="Width" Value="16"/>
      <Setter Property="Height" Value="16"/>
      <Setter Property="Stretch" Value="None"/>
      <Setter Property="Stroke" Value="#A1A1A6"/>
      <Setter Property="StrokeThickness" Value="1.5"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
      <Setter Property="StrokeStartLineCap" Value="Round"/>
      <Setter Property="StrokeEndLineCap" Value="Round"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="SnapsToDevicePixels" Value="False"/>
    </Style>
    <Style x:Key="StatIcon" TargetType="Path" BasedOn="{StaticResource RowIcon}">
      <Setter Property="Stroke" Value="#8E8E93"/>
      <Setter Property="StrokeThickness" Value="1.35"/>
      <Setter Property="RenderTransformOrigin" Value="0,0.5"/>
      <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.94" ScaleY="0.94"/></Setter.Value></Setter>
    </Style>
    <Style x:Key="RowLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#EDEDF0"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="RowPct" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F5F5F7"/>
      <Setter Property="FontSize" Value="15.5"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="6,0,10,0"/>
    </Style>
    <Style x:Key="RowSub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8E8E93"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextAlignment" Value="Right"/>
    </Style>
    <Style x:Key="StatLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8E8E93"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="StatValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="8,2,8,3"/>
      <Setter Property="Background" Value="#0DFFFFFF"/>
      <Setter Property="BorderBrush" Value="#22FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="12,10,12,4"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#1CFFFFFF"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#12FFFFFF" Offset="0"/><GradientStop Color="#08FFFFFF" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LimitBadge" TargetType="Border">
      <Setter Property="Visibility" Value="Collapsed"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
      <Setter Property="Padding" Value="7,2,9,2"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Background" Value="#26FF453A"/>
      <Setter Property="BorderBrush" Value="#99FF453A"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="IconButton" TargetType="Border">
      <Setter Property="Background" Value="#00FFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1AFFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
  <!-- ============================================================
       Quake view: a full-width terminal strip. Deliberately plain -
       monospace text, block-character gauges, no rounded corners or
       gradients - so it reads as a console, not as a widget. Content is
       built as coloured Runs from PowerShell (see QuakeView.ps1).
       ============================================================ -->
  <Border x:Name="quakeRoot" Visibility="Collapsed" BorderThickness="0,1,0,1"
          Background="#F00A0E14" BorderBrush="#FF1E3A5F">
    <Grid Margin="10,6,10,7">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="qHeader" Grid.Row="0" FontFamily="Consolas" FontSize="12"
                 Foreground="#7B9EC4" TextWrapping="NoWrap" Margin="0,0,0,4"/>
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="qClaude" Grid.Column="0" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
        <Border Grid.Column="1" Width="1" Background="#FF1E3A5F" Margin="14,2,14,2"/>
        <TextBlock x:Name="qCodex" Grid.Column="2" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
        <Border Grid.Column="3" Width="1" Background="#FF1E3A5F" Margin="14,2,14,2"/>
        <TextBlock x:Name="qCursor" Grid.Column="4" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
        <Border Grid.Column="5" Width="1" Background="#FF1E3A5F" Margin="14,2,14,2"/>
        <TextBlock x:Name="qGrok" Grid.Column="6" FontFamily="Consolas" FontSize="12"
                   Foreground="#C7D5E5" TextWrapping="NoWrap"/>
      </Grid>
      <TextBlock x:Name="qFooter" Grid.Row="2" FontFamily="Consolas" FontSize="11"
                 Foreground="#636366" TextWrapping="NoWrap" Margin="0,5,0,0"/>
    </Grid>
  </Border>

  <Grid x:Name="pinnedRoot" Width="280" Margin="12"
        HorizontalAlignment="Center" VerticalAlignment="Top" Panel.ZIndex="10"
        RenderTransformOrigin="0.5,0">
  <Grid.RenderTransform>
    <TranslateTransform x:Name="pinnedTranslate" Y="0"/>
  </Grid.RenderTransform>
  <Border x:Name="mainBorder" BorderThickness="1" CornerRadius="20" ClipToBounds="True">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0.7,1">
        <GradientStop Color="#FF0F172A" Offset="0"/>
        <GradientStop Color="#FF0B1220" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.BorderBrush>
      <SolidColorBrush Color="#FF1E3A5F"/>
    </Border.BorderBrush>
    <DockPanel>
      <StackPanel x:Name="panelContent" Margin="14,8,14,9" Width="250">
        <StackPanel.RenderTransform>
          <TranslateTransform x:Name="panelContentTranslate" Y="0"/>
        </StackPanel.RenderTransform>

        <!-- Chrome header. Drag the panel by any empty space; while it sits at
             the top a click here folds it back into the notch, and once moved
             away the "-" (in the logo slot) takes it home. -->
        <Grid x:Name="islandCollapseHeader" Margin="0,0,0,12" Background="Transparent">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="panelLogoTile" Grid.Column="0" Width="30" Height="30" CornerRadius="8" Background="#14FFFFFF"
                  BorderBrush="#1CFFFFFF" BorderThickness="1" VerticalAlignment="Center">
            <Path Data="{StaticResource IcoBars}" Stroke="#E5E5EA" StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Width="16" Height="16" Stretch="None" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Border x:Name="panelCollapseButton" Grid.Column="0" Width="30" Height="30" CornerRadius="8"
                  VerticalAlignment="Center" Cursor="Hand" SnapsToDevicePixels="True" Visibility="Collapsed"
                  BorderBrush="#1CFFFFFF" BorderThickness="1">
            <Border.Style>
              <Style TargetType="Border">
                <Setter Property="Background" Value="#14FFFFFF"/>
                <Style.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#26FFFFFF"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </Border.Style>
            <Rectangle Width="11" Height="1.8" RadiusX="0.9" RadiusY="0.9"
                       HorizontalAlignment="Center" VerticalAlignment="Center">
              <Rectangle.Style>
                <Style TargetType="Rectangle">
                  <Setter Property="Fill" Value="#AEAEB2"/>
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding IsMouseOver, RelativeSource={RelativeSource AncestorType=Border}}" Value="True">
                      <Setter Property="Fill" Value="#F2F2F7"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </Rectangle.Style>
            </Rectangle>
          </Border>
          <TextBlock Grid.Column="1" Text="AI Usage" Foreground="#F5F5F7" FontSize="18" FontWeight="Bold" FontFamily="Segoe UI"
                     VerticalAlignment="Center" Margin="10,0,12,1"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#30D158" VerticalAlignment="Center" Margin="0,1,6,0"/>
            <TextBlock x:Name="chromeStateText" Text="Live" Foreground="#A1A1A6" FontSize="12" FontFamily="Segoe UI" VerticalAlignment="Center"/>
            <!-- Written by Update-AllSections (last refresh / culprit); folded into the state text. -->
            <TextBlock x:Name="timeText" Text="" Visibility="Collapsed"/>
          </StackPanel>
          <!-- Refresh: fetch every provider now. -->
          <Border x:Name="chromeRefresh" Grid.Column="3" HorizontalAlignment="Right" Width="30" Height="30" CornerRadius="10"
                  BorderThickness="1" BorderBrush="#22FFFFFF" Margin="0,0,8,0" VerticalAlignment="Center"
                  Style="{StaticResource IconButton}" ToolTip="Refresh now">
            <Path x:Name="chromeRefreshIcon" Data="{StaticResource IcoRefresh}" Style="{StaticResource RowIcon}" Stroke="#C7C7CC"
                  HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
              <Path.RenderTransform><RotateTransform x:Name="chromeRefreshSpin" Angle="0"/></Path.RenderTransform>
            </Path>
          </Border>
          <!-- Accounts: sign in to your AIs and see which ones are signed in. -->
          <Border x:Name="chromePill" Grid.Column="4" CornerRadius="10" Padding="9,5,9,5" BorderThickness="1"
                  BorderBrush="#22FFFFFF" VerticalAlignment="Center" Style="{StaticResource IconButton}" ToolTip="Sign in to your AIs">
            <StackPanel Orientation="Horizontal">
              <Path x:Name="chromePillIcon" Data="{StaticResource IcoPerson}" Style="{StaticResource RowIcon}" Stroke="#C7C7CC"/>
              <TextBlock x:Name="chromePillText" Text="Accounts" Foreground="#E5E5EA" FontSize="12" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="7,0,6,0"/>
              <Ellipse x:Name="chromePillAlert" Width="6" Height="6" Fill="#FF453A" VerticalAlignment="Center" Margin="0,0,6,0" Visibility="Collapsed"/>
              <Path Data="{StaticResource IcoChevDown}" Style="{StaticResource RowIcon}" Stroke="#8E8E93"/>
            </StackPanel>
          </Border>
        </Grid>

        <ScrollViewer x:Name="sectionScroll"
                      VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled"
                      Template="{StaticResource OverlayScrollViewer}">
        <StackPanel x:Name="sectionStack">
        <!-- ============ CLAUDE ============ -->
        <Border x:Name="claudeSection" Style="{StaticResource Card}">
         <StackPanel>
          <Border x:Name="claudeHeader" Background="Transparent" Cursor="Hand" Margin="0,0,0,10">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="claudeIconTile" Grid.Column="0" Width="30" Height="30" CornerRadius="8" VerticalAlignment="Center">
                <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#F59E0B" Offset="0"/><GradientStop Color="#EA580C" Offset="1"/></LinearGradientBrush></Border.Background>
                <Grid>
                  <TextBlock x:Name="claudeMonogram" Text="Cl" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image x:Name="claudeIconImage" Visibility="Collapsed" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <TextBlock Grid.Column="1" Text="Claude" Foreground="#F5F5F7" FontSize="16.5" FontWeight="Bold" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="10,0,8,1"/>
              <Border x:Name="claudeVersionPill" Grid.Column="2" Style="{StaticResource Pill}">
                <TextBlock x:Name="claudeVersionText" Text="--" Foreground="#A1A1A6" FontSize="10.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="claudeHeaderDetail" Grid.Column="4" Text="" Foreground="#8E8E93" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="0,0,8,0" Visibility="Collapsed"/>
              <Border x:Name="claudeStatusPill" Grid.Column="5" CornerRadius="9" Padding="8,3,10,3" Background="#10FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="claudeStatusDot" Width="7" Height="7" Fill="#636366" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock x:Name="claudeStatusText" Text="Loading" Foreground="#A1A1A6" FontSize="11.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="claudeChevron" Grid.Column="6" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9" Foreground="#7C7C82" VerticalAlignment="Center" Margin="9,0,0,0"/>
            </Grid>
          </Border>
          <StackPanel x:Name="claudeBody">
           <Grid x:Name="claudeFull" Margin="0,0,0,4">
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel Grid.Column="0" Margin="0,0,14,0">
                <StackPanel Margin="0,0,0,9" Visibility="Visible">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="fivehIcon" Grid.Column="0" Data="{StaticResource IcoClock}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="fivehLabel" Grid.Column="1" Text="5-Hour Session" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="fivehPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="fivehReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="fivehBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="fivehSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                  <Border x:Name="fivehLimit" Style="{StaticResource LimitBadge}">
                    <StackPanel Orientation="Horizontal">
                      <Grid Width="13" Height="13" Margin="0,0,5,0" VerticalAlignment="Center">
                        <Ellipse Fill="#FF453A"/>
                        <TextBlock Text="!" Foreground="#1C0B0A" FontSize="10" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"/>
                      </Grid>
                      <TextBlock Text="Used up · limit reached" Foreground="#FF6961" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <StackPanel x:Name="fivehSparkRow" Visibility="Collapsed" Margin="24,4,0,0">
                    <Canvas x:Name="fivehSparkCanvas" Tag="track" Width="200" Height="14" HorizontalAlignment="Left">
                      <Polyline x:Name="fivehSpark" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                    </Canvas>
                  </StackPanel>
                </StackPanel>
                <StackPanel Margin="0,0,0,9" Visibility="Visible">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="weekIcon" Grid.Column="0" Data="{StaticResource IcoCalendar}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="weekLabel" Grid.Column="1" Text="Weekly Limit" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="weekPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="weekReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="weekBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="weekSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                  <Border x:Name="weekLimit" Style="{StaticResource LimitBadge}">
                    <StackPanel Orientation="Horizontal">
                      <Grid Width="13" Height="13" Margin="0,0,5,0" VerticalAlignment="Center">
                        <Ellipse Fill="#FF453A"/>
                        <TextBlock Text="!" Foreground="#1C0B0A" FontSize="10" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"/>
                      </Grid>
                      <TextBlock Text="Used up · limit reached" Foreground="#FF6961" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <StackPanel x:Name="weekSparkRow" Visibility="Collapsed" Margin="24,4,0,0">
                    <Canvas x:Name="weekSparkCanvas" Tag="track" Width="200" Height="14" HorizontalAlignment="Left">
                      <Polyline x:Name="weekSpark" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                    </Canvas>
                  </StackPanel>
                </StackPanel>
                <StackPanel Margin="0,0,0,9" Visibility="Visible">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="fabIcon" Grid.Column="0" Data="{StaticResource IcoDatabase}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="fabLabel" Grid.Column="1" Text="Fable Weekly" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="fabPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="fabReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="fabBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#6D28D9" Offset="0"/><GradientStop Color="#C084FC" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="fabSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                </StackPanel>
                <StackPanel x:Name="opusRow" Margin="0,0,0,9" Visibility="Collapsed">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="opusIcon" Grid.Column="0" Data="{StaticResource IcoBolt}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="opusLabel" Grid.Column="1" Text="Opus Weekly" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="opusPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="opusReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="opusBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#92400E" Offset="0"/><GradientStop Color="#FDE047" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="opusSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                </StackPanel>
             </StackPanel>
             <Border x:Name="statsPanel" Grid.Column="1" Width="196" BorderBrush="#16FFFFFF" BorderThickness="1,0,0,0" Padding="13,1,0,0">
               <StackPanel>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoPerson}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Account" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="claudeIdentityText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}" TextTrimming="CharacterEllipsis"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoDollar}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Est. Cost" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="valText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid x:Name="extraRow" Margin="0,0,0,6" Visibility="Collapsed">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoBolt}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Overage" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="extraVal" Text="--" Foreground="#FF9F0A" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoDatabase}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Tokens" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="tokText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoBars}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Today" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="todayText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoMoon}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="After Hrs" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="afterHoursText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoChat}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Lifetime" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="lifeText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
               </StackPanel>
             </Border>
           </Grid>
           <StackPanel x:Name="claudeCompact" Visibility="Collapsed">
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="fivehLabelC" Text="5-HOUR" Foreground="#38BDF8" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="fivehBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="fivehPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="fivehSparkRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Canvas x:Name="fivehSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="58,0,0,0">
                <Polyline x:Name="fivehSparkC" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="weekLabelC" Text="WEEKLY" Foreground="#FB923C" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="weekBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="weekPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="weekSparkRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Canvas x:Name="weekSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="58,0,0,0">
                <Polyline x:Name="weekSparkC" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="fabLabelC" Text="FABLE" Foreground="#C084FC" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="fabBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#6D28D9" Offset="0"/><GradientStop Color="#C084FC" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="fabPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <Grid x:Name="opusRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="opusLabelC" Text="OPUS" Foreground="#FDE047" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="opusBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#92400E" Offset="0"/><GradientStop Color="#FDE047" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="opusPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
           </StackPanel>
          </StackPanel>
         </StackPanel>
        </Border>
        <!-- ============ CODEX ============ -->
        <Border x:Name="codexSection" Style="{StaticResource Card}">
         <StackPanel>
          <Border x:Name="codexHeader" Background="Transparent" Cursor="Hand" Margin="0,0,0,10">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="codexIconTile" Grid.Column="0" Width="30" Height="30" CornerRadius="8" VerticalAlignment="Center">
                <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#6366F1" Offset="0"/><GradientStop Color="#8B5CF6" Offset="1"/></LinearGradientBrush></Border.Background>
                <Grid>
                  <TextBlock x:Name="codexMonogram" Text="Cx" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image x:Name="codexIconImage" Visibility="Collapsed" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <TextBlock Grid.Column="1" Text="Codex" Foreground="#F5F5F7" FontSize="16.5" FontWeight="Bold" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="10,0,8,1"/>
              <Border x:Name="codexVersionPill" Grid.Column="2" Style="{StaticResource Pill}">
                <TextBlock x:Name="codexVersionText" Text="--" Foreground="#A1A1A6" FontSize="10.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="codexHeaderDetail" Grid.Column="4" Text="" Foreground="#8E8E93" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="0,0,8,0" Visibility="Collapsed"/>
              <Border x:Name="codexStatusPill" Grid.Column="5" CornerRadius="9" Padding="8,3,10,3" Background="#10FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="codexStatusDot" Width="7" Height="7" Fill="#636366" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock x:Name="codexStatusText" Text="Loading" Foreground="#A1A1A6" FontSize="11.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="codexChevron" Grid.Column="6" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9" Foreground="#7C7C82" VerticalAlignment="Center" Margin="9,0,0,0"/>
            </Grid>
          </Border>
          <StackPanel x:Name="codexBody">
           <Grid x:Name="codexFull" Margin="0,0,0,4">
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel Grid.Column="0" Margin="0,0,14,0">
                <TextBlock x:Name="codexErrText" Text="" Foreground="#A1A1A6" FontSize="12" FontFamily="Segoe UI"
                           TextWrapping="Wrap" Margin="24,0,0,9" Visibility="Collapsed"/>
                <StackPanel x:Name="codexFivehRow" Margin="0,0,0,9" Visibility="Collapsed">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="codexFivehIcon" Grid.Column="0" Data="{StaticResource IcoClock}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="codexFivehLabel" Grid.Column="1" Text="5-Hour Session" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="codexFivehPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="codexFivehReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="codexFivehBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="codexFivehSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                  <Border x:Name="codexFivehLimit" Style="{StaticResource LimitBadge}">
                    <StackPanel Orientation="Horizontal">
                      <Grid Width="13" Height="13" Margin="0,0,5,0" VerticalAlignment="Center">
                        <Ellipse Fill="#FF453A"/>
                        <TextBlock Text="!" Foreground="#1C0B0A" FontSize="10" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"/>
                      </Grid>
                      <TextBlock Text="Used up · limit reached" Foreground="#FF6961" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <StackPanel x:Name="codexFivehSparkRow" Visibility="Collapsed" Margin="24,4,0,0">
                    <Canvas x:Name="codexFivehSparkCanvas" Tag="track" Width="200" Height="14" HorizontalAlignment="Left">
                      <Polyline x:Name="codexFivehSpark" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                    </Canvas>
                  </StackPanel>
                </StackPanel>
                <StackPanel Margin="0,0,0,9" Visibility="Visible">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="codexWeekIcon" Grid.Column="0" Data="{StaticResource IcoCalendar}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="codexWeekLabel" Grid.Column="1" Text="Weekly Limit" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="codexWeekPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="codexWeekReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="codexWeekBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="codexWeekSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                  <Border x:Name="codexWeekLimit" Style="{StaticResource LimitBadge}">
                    <StackPanel Orientation="Horizontal">
                      <Grid Width="13" Height="13" Margin="0,0,5,0" VerticalAlignment="Center">
                        <Ellipse Fill="#FF453A"/>
                        <TextBlock Text="!" Foreground="#1C0B0A" FontSize="10" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"/>
                      </Grid>
                      <TextBlock Text="Used up · limit reached" Foreground="#FF6961" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <StackPanel x:Name="codexWeekSparkRow" Visibility="Collapsed" Margin="24,4,0,0">
                    <Canvas x:Name="codexWeekSparkCanvas" Tag="track" Width="200" Height="14" HorizontalAlignment="Left">
                      <Polyline x:Name="codexWeekSpark" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                    </Canvas>
                  </StackPanel>
                </StackPanel>
                <Grid x:Name="codexResetsRow" Margin="0,0,0,9">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Path Grid.Column="0" Data="{StaticResource IcoRefresh}" Style="{StaticResource RowIcon}" Stroke="#30D158"/>
                  <TextBlock Grid.Column="1" Text="Resets" Foreground="#A1A1A6" FontSize="12.5" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <TextBlock Grid.Column="2" x:Name="codexResetsText" Text="--" Foreground="#30D158" FontSize="12.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
                  <Path Grid.Column="3" Data="{StaticResource IcoInfo}" Style="{StaticResource StatIcon}" Margin="9,0,0,0" Cursor="Help"
                        ToolTip="One-time usage resets you can redeem on the Codex usage page."/>
                </Grid>
             </StackPanel>
             <Border Grid.Column="1" Width="196" BorderBrush="#16FFFFFF" BorderThickness="1,0,0,0" Padding="13,1,0,0">
               <StackPanel>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoDollar}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Est. Cost" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="codexValText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoDatabase}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Tokens" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="codexTokText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoBars}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Today" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="codexTodayText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoMoon}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="After Hrs" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="codexAfterHoursText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoChat}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Lifetime" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="codexSessText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
               </StackPanel>
             </Border>
           </Grid>
           <StackPanel x:Name="codexCompact" Visibility="Collapsed">
            <StackPanel x:Name="codexFivehRowC" Visibility="Collapsed">
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="codexFivehLabelC" Text="5-HOUR" Foreground="#38BDF8" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="codexFivehBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0369A1" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="codexFivehPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="codexFivehSparkRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Canvas x:Name="codexFivehSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="58,0,0,0">
                <Polyline x:Name="codexFivehSparkC" Stroke="#38BDF8" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
            </StackPanel>
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="codexWeekLabelC" Text="WEEKLY" Foreground="#FB923C" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="codexWeekBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#C2410C" Offset="0"/><GradientStop Color="#FB923C" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="codexWeekPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="codexWeekSparkRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Canvas x:Name="codexWeekSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="58,0,0,0">
                <Polyline x:Name="codexWeekSparkC" Stroke="#FB923C" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
           </StackPanel>
          </StackPanel>
         </StackPanel>
        </Border>
        <!-- ============ CURSOR ============ -->
        <Border x:Name="cursorSection" Style="{StaticResource Card}">
         <StackPanel>
          <Border x:Name="cursorHeader" Background="Transparent" Cursor="Hand" Margin="0,0,0,10">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="cursorIconTile" Grid.Column="0" Width="30" Height="30" CornerRadius="8" VerticalAlignment="Center">
                <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#334155" Offset="0"/><GradientStop Color="#0F172A" Offset="1"/></LinearGradientBrush></Border.Background>
                <Grid>
                  <TextBlock x:Name="cursorMonogram" Text="Cu" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image x:Name="cursorIconImage" Visibility="Collapsed" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <TextBlock Grid.Column="1" Text="Cursor" Foreground="#F5F5F7" FontSize="16.5" FontWeight="Bold" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="10,0,8,1"/>
              <Border x:Name="cursorVersionPill" Grid.Column="2" Style="{StaticResource Pill}">
                <TextBlock x:Name="cursorVersionText" Text="--" Foreground="#A1A1A6" FontSize="10.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="cursorHeaderDetail" Grid.Column="4" Text="" Foreground="#8E8E93" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="0,0,8,0" Visibility="Collapsed"/>
              <Border x:Name="cursorStatusPill" Grid.Column="5" CornerRadius="9" Padding="8,3,10,3" Background="#10FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="cursorStatusDot" Width="7" Height="7" Fill="#636366" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock x:Name="cursorStatusText" Text="Loading" Foreground="#A1A1A6" FontSize="11.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="cursorChevron" Grid.Column="6" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9" Foreground="#7C7C82" VerticalAlignment="Center" Margin="9,0,0,0"/>
            </Grid>
          </Border>
          <StackPanel x:Name="cursorBody">
           <Grid x:Name="cursorFull" Margin="0,0,0,4">
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel Grid.Column="0" Margin="0,0,14,0">
                <StackPanel Margin="0,0,0,9" Visibility="Visible">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="reqIcon" Grid.Column="0" Data="{StaticResource IcoLayers}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="reqLabel" Grid.Column="1" Text="Models" Style="{StaticResource RowLabel}"/>
                    <Border x:Name="overPill" Grid.Column="2" Background="#1F1400" BorderBrush="#FF9F0A" BorderThickness="1" CornerRadius="5"
                            Padding="5,1,5,1" VerticalAlignment="Center" Margin="0,0,6,0" Visibility="Collapsed">
                      <TextBlock Text="over" Foreground="#FF9F0A" FontSize="10" FontFamily="Segoe UI Semibold"/>
                    </Border>
                    <TextBlock x:Name="reqCount" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="reqReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border x:Name="barTrack" Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="reqBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#065F46" Offset="0"/><GradientStop Color="#34D399" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="reqSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                  <StackPanel x:Name="cursorReqSparkRow" Visibility="Collapsed" Margin="24,4,0,0">
                    <Canvas x:Name="cursorReqSparkCanvas" Tag="track" Width="200" Height="14" HorizontalAlignment="Left">
                      <Polyline x:Name="cursorReqSpark" Stroke="#34D399" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                    </Canvas>
                  </StackPanel>
                </StackPanel>
                <Grid x:Name="otherModelsRow" Margin="0,0,0,6">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Path Grid.Column="0" Data="{StaticResource IcoLayers}" Style="{StaticResource StatIcon}"/>
                  <TextBlock x:Name="otherModelsLabel" Grid.Column="1" Text="Other models" Style="{StaticResource StatLabel}"/>
                  <TextBlock x:Name="otherModelsText" Grid.Column="2" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                </Grid>
                <Grid x:Name="onDemandRow" Margin="0,0,0,6">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Path Grid.Column="0" Data="{StaticResource IcoDollar}" Style="{StaticResource StatIcon}"/>
                  <TextBlock x:Name="onDemandLabel" Grid.Column="1" Text="On-demand" Style="{StaticResource StatLabel}"/>
                  <TextBlock x:Name="onDemandText" Grid.Column="2" Text="--" Foreground="#8E8E93" Style="{StaticResource StatValue}"/>
                </Grid>
             </StackPanel>
             <Border Grid.Column="1" Width="196" BorderBrush="#16FFFFFF" BorderThickness="1,0,0,0" Padding="13,1,0,0">
               <StackPanel>
                  <StackPanel x:Name="cursorAnalyticsBlock" Visibility="Collapsed">
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoBolt}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" x:Name="editsLabel" Text="Edits" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="editsText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoBars}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" x:Name="cursorTodayLabel" Text="Today" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="cursorTodayText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoLayers}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" x:Name="cursorModelLabel" Text="Model" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="cursorModelText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}" TextTrimming="CharacterEllipsis"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoList}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" x:Name="cursorSessLabel" Text="Lines" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="cursorSessText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
                  </StackPanel>
               </StackPanel>
             </Border>
           </Grid>
           <StackPanel x:Name="cursorCompact" Visibility="Collapsed">
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="reqLabelC" Text="MODELS" Foreground="#34D399" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="reqBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#065F46" Offset="0"/><GradientStop Color="#34D399" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="reqCountC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions><ColumnDefinition Width="58"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="otherModelsLabelC" Text="OTHER" Foreground="#34D399" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="otherModelsTextC" Text="--" Foreground="#A1A1A6" FontSize="12" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right"/>
            </Grid>
            <StackPanel x:Name="cursorReqSparkRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Canvas x:Name="cursorReqSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="58,0,0,0">
                <Polyline x:Name="cursorReqSparkC" Stroke="#34D399" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
           </StackPanel>
          </StackPanel>
         </StackPanel>
        </Border>
        <!-- ============ GROK ============ -->
        <Border x:Name="grokSection" Style="{StaticResource Card}">
         <StackPanel>
          <Border x:Name="grokHeader" Background="Transparent" Cursor="Hand" Margin="0,0,0,10">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="grokIconTile" Grid.Column="0" Width="30" Height="30" CornerRadius="8" VerticalAlignment="Center">
                <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#52525B" Offset="0"/><GradientStop Color="#18181B" Offset="1"/></LinearGradientBrush></Border.Background>
                <Grid>
                  <TextBlock x:Name="grokMonogram" Text="Gk" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image x:Name="grokIconImage" Visibility="Collapsed" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <TextBlock Grid.Column="1" Text="Grok" Foreground="#F5F5F7" FontSize="16.5" FontWeight="Bold" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="10,0,8,1"/>
              <Border x:Name="grokVersionPill" Grid.Column="2" Style="{StaticResource Pill}">
                <TextBlock x:Name="grokVersionText" Text="--" Foreground="#A1A1A6" FontSize="10.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="grokHeaderDetail" Grid.Column="4" Text="" Foreground="#8E8E93" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center" Margin="0,0,8,0" Visibility="Collapsed"/>
              <Border x:Name="grokStatusPill" Grid.Column="5" CornerRadius="9" Padding="8,3,10,3" Background="#10FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="grokStatusDot" Width="7" Height="7" Fill="#636366" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock x:Name="grokStatusText" Text="Loading" Foreground="#A1A1A6" FontSize="11.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="grokChevron" Grid.Column="6" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9" Foreground="#7C7C82" VerticalAlignment="Center" Margin="9,0,0,0"/>
            </Grid>
          </Border>
          <StackPanel x:Name="grokBody">
           <Grid x:Name="grokFull" Margin="0,0,0,4">
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel Grid.Column="0" Margin="0,0,14,0">
                <TextBlock x:Name="grokErrText" Text="" Foreground="#A1A1A6" FontSize="12" FontFamily="Segoe UI"
                           TextWrapping="Wrap" Margin="24,0,0,9" Visibility="Collapsed"/>
                <StackPanel Margin="0,0,0,9" Visibility="Visible">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto" MinWidth="72"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="grokWeekIcon" Grid.Column="0" Data="{StaticResource IcoCalendar}" Style="{StaticResource RowIcon}"/>
                    <TextBlock x:Name="grokWeekLabel" Grid.Column="1" Text="Weekly Limit" Style="{StaticResource RowLabel}"/>
                    <TextBlock x:Name="grokWeekPct" Grid.Column="3" Text="--" Style="{StaticResource RowPct}"/>
                    <TextBlock x:Name="grokWeekReset" Grid.Column="4" Text="" Style="{StaticResource RowSub}"/>
                  </Grid>
                  <Border Tag="track" Height="5" CornerRadius="2.5" Background="#1CFFFFFF" Width="200" HorizontalAlignment="Left" Margin="24,6,0,0">
                    <Border x:Name="grokWeekBar" Height="5" CornerRadius="2.5" HorizontalAlignment="Left" Width="0">
                      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#A16207" Offset="0"/><GradientStop Color="#FDE68A" Offset="1"/></LinearGradientBrush></Border.Background>
                    </Border>
                  </Border>
                  <TextBlock x:Name="grokWeekSub" Visibility="Collapsed" Text="used" Foreground="#7C7C82" FontSize="10.5" FontFamily="Segoe UI" Margin="24,3,0,0"/>
                  <Border x:Name="grokWeekLimit" Style="{StaticResource LimitBadge}">
                    <StackPanel Orientation="Horizontal">
                      <Grid Width="13" Height="13" Margin="0,0,5,0" VerticalAlignment="Center">
                        <Ellipse Fill="#FF453A"/>
                        <TextBlock Text="!" Foreground="#1C0B0A" FontSize="10" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"/>
                      </Grid>
                      <TextBlock Text="Used up · limit reached" Foreground="#FF6961" FontSize="11" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <StackPanel x:Name="grokWeekSparkRow" Visibility="Collapsed" Margin="24,4,0,0">
                    <Canvas x:Name="grokWeekSparkCanvas" Tag="track" Width="200" Height="14" HorizontalAlignment="Left">
                      <Polyline x:Name="grokWeekSpark" Stroke="#FDE68A" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                    </Canvas>
                  </StackPanel>
                </StackPanel>
             </StackPanel>
             <Border Grid.Column="1" Width="196" BorderBrush="#16FFFFFF" BorderThickness="1,0,0,0" Padding="13,1,0,0">
               <StackPanel>
                  <Grid Margin="0,0,0,6">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoBars}" Style="{StaticResource StatIcon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                    <TextBlock Grid.Column="1" Text="Usage" Style="{StaticResource StatLabel}" VerticalAlignment="Top"/>
                    <TextBlock Grid.Column="2" x:Name="grokPlanText" Text="--" Foreground="#A1A1A6" FontSize="11.5" FontFamily="Segoe UI" TextWrapping="Wrap" LineHeight="16"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoRefresh}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Resets" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="grokResetsText" Text="--" Foreground="#30D158" Style="{StaticResource StatValue}"/>
                  </Grid>
                  <Grid Margin="0,0,0,6" Visibility="Visible">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="19"/><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Path Grid.Column="0" Data="{StaticResource IcoDollar}" Style="{StaticResource StatIcon}"/>
                    <TextBlock Grid.Column="1" Text="Prepaid" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Column="2" x:Name="grokPrepaidText" Text="--" Foreground="#EDEDF0" Style="{StaticResource StatValue}"/>
                  </Grid>
               </StackPanel>
             </Border>
           </Grid>
           <StackPanel x:Name="grokCompact" Visibility="Collapsed">
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="58"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="grokWeekLabelC" Text="WEEKLY" Foreground="#FDE68A" FontSize="10.5" FontFamily="Segoe UI Semibold" VerticalAlignment="Center"/>
              <Border Grid.Column="1" Height="6" CornerRadius="3" Background="#1CFFFFFF" Width="120" HorizontalAlignment="Left" VerticalAlignment="Center">
                <Border x:Name="grokWeekBarC" Height="6" CornerRadius="3" HorizontalAlignment="Left" Width="0">
                  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#A16207" Offset="0"/><GradientStop Color="#FDE68A" Offset="1"/></LinearGradientBrush></Border.Background>
                </Border>
              </Border>
              <TextBlock Grid.Column="2" x:Name="grokWeekPctC" Text="--" Foreground="#F5F5F7" FontSize="13" FontFamily="Segoe UI Semibold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel x:Name="grokWeekSparkRowC" Visibility="Collapsed" Margin="0,0,0,8">
              <Canvas x:Name="grokWeekSparkCanvasC" Width="120" Height="14" HorizontalAlignment="Left" Margin="58,0,0,0">
                <Polyline x:Name="grokWeekSparkC" Stroke="#FDE68A" StrokeThickness="1.5" StrokeLineJoin="Round"/>
              </Canvas>
            </StackPanel>
           </StackPanel>
          </StackPanel>
         </StackPanel>
        </Border>
        </StackPanel>
        </ScrollViewer>

        <Border x:Name="footerDivider" Height="1" Background="#16FFFFFF" Margin="0,0,0,9"/>
        <Grid x:Name="footerRow">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid Width="17" Height="17" Margin="4,0,8,0" VerticalAlignment="Center">
            <Viewbox x:Name="brandMarkBox" Stretch="Uniform">
              <Canvas Width="32" Height="32">
                <Path x:Name="brandPath" Fill="#A1A1A6" Data="M11,5 H26 V9 H22 V20 C22,24 19.5,27 15.5,27 H13 C9,27 6,24 6,20 V18 H10 V20 C10,21.8 11.2,23 13,23 H15.5 C17,23 18,21.8 18,20 V9 H11 Z"/>
              </Canvas>
            </Viewbox>
            <Image x:Name="brandMarkImage" Stretch="Uniform" Visibility="Collapsed"/>
          </Grid>
          <TextBlock x:Name="brandLabel" Grid.Column="1" Text="JayOS" Foreground="#A1A1A6" FontSize="12.5" FontFamily="Segoe UI" VerticalAlignment="Center"/>
          <TextBlock x:Name="versionLabel" Grid.Column="2" Text="0.0.1 beta" Foreground="#7C7C82" FontSize="11" FontFamily="Segoe UI"
                     VerticalAlignment="Center" HorizontalAlignment="Right" Margin="8,0,10,0"/>
          <Border x:Name="footerSettingsButton" Grid.Column="3" Width="26" Height="26" CornerRadius="7" Style="{StaticResource IconButton}"
                  ToolTip="Settings">
            <Path Data="{StaticResource IcoSliders}" Style="{StaticResource RowIcon}" Stroke="#AEAEB2" HorizontalAlignment="Center"/>
          </Border>
        </Grid>

      </StackPanel>
    </DockPanel>
  </Border>
  </Grid>
  </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
# Set-SectionBar - local copy of Ui.ps1 Set-Bar so Claude bars render without
# depending on Ui.ps1 (Leg E does not dot-source Ui.ps1). Shows REMAINING/used %.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Set-BarWidth - eases a progress bar to a new Width instead of snapping.
# Mirrors the Toggle-Section height-animation contract: any in-flight animation
# is cleared (BeginAnimation $null) before we touch Width, and on Completed the
# held value is handed back to the real DP - otherwise FillBehavior=HoldEnd pins
# Width and silently swallows every later refresh's assignment (bars freeze).
# Animates from the current ON-SCREEN width (ActualWidth) so mid-tween refreshes
# hand off smoothly; sub-pixel deltas skip the tween to avoid per-refresh churn.
# ---------------------------------------------------------------------------
function Set-BarWidth($b, [double]$target) {
    if (-not $b) { return }
    $wp  = [System.Windows.FrameworkElement]::WidthProperty
    # Hidden bars (collapsed section, or the inactive full/compact layout) skip the
    # tween: their ActualWidth is 0, so every refresh would re-animate 0->target for
    # nothing. Set the value directly so it's correct the moment they become visible.
    if (-not $b.IsVisible) { $b.BeginAnimation($wp, $null); $b.Width = $target; return }
    $cur = $b.ActualWidth
    if ([double]::IsNaN($cur) -or $cur -lt 0) { $cur = 0 }
    $b.BeginAnimation($wp, $null)
    if ([math]::Abs($target - $cur) -lt 1) { $b.Width = $target; return }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From     = $cur
    $anim.To       = $target
    $anim.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(220))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease
    $bb = $b; $t = $target
    $anim.Add_Completed({
        $bb.BeginAnimation($wp, $null)
        $bb.Width = $t
    }.GetNewClosure())
    $b.BeginAnimation($wp, $anim)
}


# Usage bands: green while there is plenty left, yellow from 60 %, red from
# 85 %. Bars, their percentages, row icons and the notch readout share them.
$script:BandYellowPct = 60
$script:BandRedPct    = 85
function Get-UsageBandColor($util) {
    if ($null -eq $util) { return $null }
    $u = [double]$util
    if ($u -ge $script:BandRedPct) { return '#FF453A' }
    if ($u -ge $script:BandYellowPct) { return '#FFD60A' }
    return '#30D158'
}

function Test-ThemeStateBars {
    $t = if ($script:Cfg -and $script:Themes) { $script:Themes[[string]$script:Cfg.Theme] } else { $null }
    return [bool]($t -and $t.StateBars)
}

function Resolve-PctAccentFg($util, [string]$AccentFg) {
    if ($null -ne $util -and (Test-ThemeStateBars)) { return (Get-UsageBandColor $util) }
    # Warn/crit still win; otherwise paint primary % in the provider bar hue.
    if ($null -eq $util) { return '#F5F5F7' }
    $u = [double]$util
    if ($u -ge $script:CritPct) { return '#FF453A' }
    if ($u -ge $script:WarnPct) { return '#FF9F0A' }
    if (-not [string]::IsNullOrWhiteSpace($AccentFg)) { return $AccentFg }
    return '#F5F5F7'
}

function Set-PctAccentStyle($el, [string]$fg, [switch]$Compact) {
    if (-not $el) { return }
    $el.Foreground = NewBrush $fg
    # Slightly bolder than the surrounding secondary stats.
    $el.FontWeight = if ($Compact) {
        [System.Windows.FontWeights]::SemiBold
    } else {
        [System.Windows.FontWeights]::Bold
    }
}

function Set-GrokProductUsageVisual($tb, [string]$text, [string]$AccentFg) {
    # Stacked chips: name stays muted; trailing N% uses Grok bar hue.
    if (-not $tb) { return }
    $tb.Text = $null
    $tb.Inlines.Clear()
    $accent = if (-not [string]::IsNullOrWhiteSpace($AccentFg)) { $AccentFg } else { '#FDE68A' }
    $muted = '#98989D'
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq '--') {
        $run = New-Object System.Windows.Documents.Run('--')
        $run.Foreground = NewBrush $muted
        [void]$tb.Inlines.Add($run)
        return
    }
    $lines = [regex]::Split([string]$text, '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -gt 0) { [void]$tb.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
        $line = $lines[$i]
        if ($line -match '^(.*?)(\s+)(\d+%)$') {
            $nameRun = New-Object System.Windows.Documents.Run($Matches[1])
            $nameRun.Foreground = NewBrush $muted
            $gap = New-Object System.Windows.Documents.Run($Matches[2])
            $gap.Foreground = NewBrush $muted
            $pctRun = New-Object System.Windows.Documents.Run($Matches[3])
            $pctRun.Foreground = NewBrush $accent
            $pctRun.FontWeight = [System.Windows.FontWeights]::Bold
            [void]$tb.Inlines.Add($nameRun)
            [void]$tb.Inlines.Add($gap)
            [void]$tb.Inlines.Add($pctRun)
        } else {
            $run = New-Object System.Windows.Documents.Run($line)
            $run.Foreground = NewBrush $muted
            [void]$tb.Inlines.Add($run)
        }
    }
}

# Set-BarSubText - writes a bar's sub-label and collapses the row when the text
# is the bare 'used' filler. That row costs ~12 DIP and repeats under all six
# metrics; hiding it is what buys the fully-expanded accordion its screen fit.
# Warn/crit words and Cursor's request count are information, so they stay.
function Set-BarSubText($el, [string]$text) {
    if (-not $el) { return }
    $el.Text = $text
    $el.Visibility = if (Test-BarSubVisible $text) {
        [System.Windows.Visibility]::Visible
    } else {
        [System.Windows.Visibility]::Collapsed
    }
}

# Carried-forward Claude numbers stay on screen - they are the last real
# reading - but a countdown drawn from a reset time we can no longer refresh is
# not. Say when the numbers were read instead.
function Format-ClaudeStaleReset([string]$AsOf) {
    if ([string]::IsNullOrWhiteSpace($AsOf)) { return 'stale' }
    return ('as of {0}' -f $AsOf.Trim())
}

# Themes with StateBars (Graphite) keep meters neutral and colour only the
# ones that need attention: orange from the warn level, red from critical.
function Set-BarStateBrush($Bar, $Util) {
    if (-not $Bar) { return }
    if (-not $script:BarBaseBrush) { $script:BarBaseBrush = @{} }
    $name = [string]$Bar.Name
    $icon = $script:window.FindName(($name -replace 'Bar(C?)$', 'Icon$1'))
    if (-not (Test-ThemeStateBars) -or $null -eq $Util) {
        if ($script:BarBaseBrush.ContainsKey($name)) {
            $Bar.Background = $script:BarBaseBrush[$name]
            [void]$script:BarBaseBrush.Remove($name)
        }
        if ($icon -and (Test-ThemeStateBars)) { $icon.Stroke = NewBrush '#8E8E93' }
        return
    }
    if (-not $script:BarBaseBrush.ContainsKey($name)) { $script:BarBaseBrush[$name] = $Bar.Background }
    $u = [double]$Util
    $Bar.Background = if ($u -ge $script:BandRedPct) { New-GradientBrush '#D70015' '#FF453A' }
                      elseif ($u -ge $script:BandYellowPct) { New-GradientBrush '#C9A000' '#FFD60A' }
                      else { New-GradientBrush '#248A3D' '#30D158' }
    if ($icon) { $icon.Stroke = NewBrush (Get-UsageBandColor $u) }
}

function Set-SectionBar([string]$bar, [string]$pct, [string]$sub, [string]$reset, $util, $resetsAt, [string]$AccentFg = $null, [string]$ResetOverride = $null) {
    $b  = $script:window.FindName($bar)
    $p  = $script:window.FindName($pct)
    $sb = if ($sub)   { $script:window.FindName($sub)   } else { $null }
    $r  = if ($reset) { $script:window.FindName($reset) } else { $null }
    if (-not $b -or -not $p) { return }
    Set-BarStateBrush $b $util
    if ($null -eq $util) {
        Set-BarWidth $b 0; $p.Text = '--'; Set-PctAccentStyle $p '#F5F5F7'
        if ($sb) { Set-BarSubText $sb 'used' }
        if ($r)  { $r.Text  = '' }
        return
    }
    $u        = [double]$util
    Set-BarWidth $b ([math]::Max(0, [math]::Min($script:BarTrackWidth, [math]::Round($u / 100.0 * $script:BarTrackWidth))))
    $p.Text   = ('{0:0}%' -f $u)
    Set-PctAccentStyle $p (Resolve-PctAccentFg $u $AccentFg)
    if ($sb) {
        $subText = if ($u -ge $script:CritPct) { 'critical!' } elseif ($u -ge $script:WarnPct) { 'high' } else { 'used' }
        Set-BarSubText $sb $subText
    }
    if ($r) {
        if ($ResetOverride) { $r.Text = $ResetOverride } else { $r.Text = Format-PanelReset $resetsAt }
    }
}

# Panel wording for a reset countdown: "4h 58m remaining" / "3d 20h remaining".
# The compact header detail and the Quake view keep Format-Reset's short glyph form.
function Format-PanelReset([string]$iso) {
    if (-not $iso) { return '' }
    try {
        $span = [System.DateTimeOffset]::Parse($iso) - [System.DateTimeOffset]::Now
        if ($span.TotalSeconds -le 0) { return 'resetting now' }
        if ($span.TotalDays  -ge 1) { return ('{0}d {1}h left' -f [int][math]::Floor($span.TotalDays), $span.Hours) }
        if ($span.TotalHours -ge 1) { return ('{0}h {1:00}m left' -f [int][math]::Floor($span.TotalHours), $span.Minutes) }
        return ('{0}m left' -f [int][math]::Max(1, [math]::Floor($span.TotalMinutes)))
    } catch { return '' }
}

# ---------------------------------------------------------------------------
# Set-CompactBar - single-line compact row: fills the narrow bar and sets the %
# text (same warn/crit foreground as the full view). Safe no-op until the
# compact XAML exists (FindName returns null for missing elements).
# ---------------------------------------------------------------------------
function Set-CompactBar([string]$bar, [string]$pct, $util, [string]$AccentFg = $null) {
    $b = $script:window.FindName($bar)
    $p = $script:window.FindName($pct)
    if (-not $b -or -not $p) { return }
    Set-BarStateBrush $b $util
    if ($null -eq $util) {
        Set-BarWidth $b 0; $p.Text = '--'; Set-PctAccentStyle $p '#F5F5F7' -Compact
        return
    }
    $u = [double]$util
    Set-BarWidth $b ([math]::Max(0, [math]::Min($script:CompactBarWidth, [math]::Round($u / 100.0 * $script:CompactBarWidth))))
    $p.Text = ('{0:0}%' -f $u)
    Set-PctAccentStyle $p (Resolve-PctAccentFg $u $AccentFg) -Compact
}

# ---------------------------------------------------------------------------
# Set-Spark - renders a sparkline polyline onto a named Canvas
# ---------------------------------------------------------------------------
function Set-Spark([string]$sparkName, [string]$canvasName, [string]$metricKey, [string]$rowName = $null) {
    $spark  = $script:window.FindName($sparkName)
    $canvas = $script:window.FindName($canvasName)
    $row    = if ($rowName) { $script:window.FindName($rowName) } else { $null }
    $hide = {
        if ($row) { $row.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    if (-not $spark -or -not $canvas) { & $hide; return }
    $spark.Points.Clear()

    $showGraph = $script:Cfg -and [bool]$script:Cfg.ShowGraph
    $samples = $script:History
    if (-not $showGraph -or $null -eq $samples -or $samples.Count -lt 2) { & $hide; return }

    $valid = @($samples | Where-Object { $null -ne $_.$metricKey })
    if ($valid.Count -lt 2) { & $hide; return }
    if ($row) { $row.Visibility = [System.Windows.Visibility]::Visible }

    # X: time range; Y: utilization 0-100 mapped to canvas height (inverted: 0% at bottom, 100% at top)
    $w = $canvas.Width
    $h = $canvas.Height

    $t0 = [System.DateTimeOffset]::Parse($valid[0].t)
    $t1 = [System.DateTimeOffset]::Parse($valid[-1].t)
    $tRange = ($t1 - $t0).TotalSeconds
    if ($tRange -le 0) { return }

    foreach ($s in $valid) {
        $tSec = ([System.DateTimeOffset]::Parse($s.t) - $t0).TotalSeconds
        $x = [double]($tSec / $tRange) * $w
        $y = $h - ([math]::Max(0, [math]::Min(100, [double]($s.$metricKey))) / 100.0 * $h)
        [void]$spark.Points.Add([System.Windows.Point]::new($x, $y))
    }
}

# ---------------------------------------------------------------------------
# Apply-UnifiedTheme - applies $script:Themes[$name] across the chrome and all
# three sections. Mirrors Ui.ps1 Apply-Theme; extends to codex/cursor. Greyscale-safe.
# ---------------------------------------------------------------------------
function Get-OverlayBrandPngPath {
    Join-Path $env:LOCALAPPDATA 'AIUsageOverlay\brand.png'
}

function Apply-FooterBrandMark {
    $img = $script:window.FindName('brandMarkImage')
    $box = $script:window.FindName('brandMarkBox')
    if (-not $img -or -not $box) { return }

    $path = Get-OverlayBrandPngPath
    $ok = $false
    if (Test-Path -LiteralPath $path) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $stream = [System.IO.File]::OpenRead($path)
            try {
                $bmp.StreamSource = $stream
                $bmp.EndInit()
            } finally {
                $stream.Dispose()
            }
            if ($bmp.CanFreeze) { $bmp.Freeze() }
            $img.Source = $bmp
            $ok = $true
        } catch {
            $img.Source = $null
        }
    }

    if ($ok) {
        $img.Visibility = [System.Windows.Visibility]::Visible
        $box.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $img.Source = $null
        $img.Visibility = [System.Windows.Visibility]::Collapsed
        $box.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Invoke-SetFooterBrand {
    # Tray-discoverable: pick a PNG into the documented drop path, then repaint.
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'PNG image (*.png)|*.png|All files (*.*)|*.*'
    $dlg.Title = 'Choose footer brand PNG'
    $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $dest = Get-OverlayBrandPngPath
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    try {
        Copy-Item -LiteralPath $dlg.FileName -Destination $dest -Force
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Set footer brand failed: $($_.Exception.Message)"
        }
        return
    }
    Apply-FooterBrandMark
}

function Invoke-ResetFooterBrand {
    $path = Get-OverlayBrandPngPath
    if (Test-Path -LiteralPath $path) {
        try { Remove-Item -LiteralPath $path -Force } catch { }
    }
    Apply-FooterBrandMark
}

# ---------------------------------------------------------------------------
# Update-FooterVersion - footer version label in the theme's brand colour.
# ---------------------------------------------------------------------------
function Update-FooterVersion {
    if (-not $script:window) { return }
    $el = $script:window.FindName('versionLabel')
    if (-not $el) { return }
    $el.Text = if ($script:DisplayVersion) { [string]$script:DisplayVersion } else { '0.0.1 beta' }
    $fg = '#7C7C82'
    if ($script:Cfg -and $script:Themes) {
        $t = $script:Themes[[string]$script:Cfg.Theme]
        if ($t -and $t.BrandLabelFg) { $fg = [string]$t.BrandLabelFg }
    }
    $el.Foreground = NewBrush $fg
}

function Apply-UnifiedTheme([string]$name) {
    $t = $script:Themes[$name]
    if (-not $t) { return }
    # Bars are repainted below; state colours are re-applied on the next refresh.
    $script:BarBaseBrush = @{}

    # Main panel background and border
    $mb = $script:window.FindName('mainBorder')
    if ($mb -and $t.BgC1) {
        $mb.Background  = New-GradientBrush2 $t.BgC1 $t.BgC2
        $mb.BorderBrush = NewBrush $t.BorderC1
    }

    $brand = $script:window.FindName('brandLabel')
    if ($brand -and $t.BrandLabelFg) { $brand.Foreground = NewBrush $t.BrandLabelFg }
    $bp = $script:window.FindName('brandPath')
    if ($bp -and $t.BrandLabelFg) { $bp.Fill = NewBrush $t.BrandLabelFg }
    Apply-FooterBrandMark
    Update-FooterVersion

    # Claude/Codex bars/labels/subs
    $bars   = @('fivehBar','weekBar','fabBar','opusBar','codexWeekBar','fivehBarC','weekBarC','fabBarC','opusBarC','codexWeekBarC','codexFivehBar','codexFivehBarC')
    $labels = @('fivehLabel','weekLabel','fabLabel','opusLabel','codexWeekLabel','fivehLabelC','weekLabelC','fabLabelC','opusLabelC','codexWeekLabelC','codexFivehLabel','codexFivehLabelC')
    $subs   = @('fivehSub','weekSub','fabSub','opusSub','codexWeekSub','','','','','','codexFivehSub','')
    $fgKeys = @('FivehFg','WeekFg','FabFg','OpusFg','WeekFg','FivehFg','WeekFg','FabFg','OpusFg','WeekFg','FivehFg','FivehFg')
    $bgKeys = @('FivehColors','WeekColors','FabColors','OpusColors','WeekColors','FivehColors','WeekColors','FabColors','OpusColors','WeekColors','FivehColors','FivehColors')
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $b = $script:window.FindName($bars[$i])
        if ($b -and $t[$bgKeys[$i]]) { $b.Background = New-GradientBrush $t[$bgKeys[$i]][0] $t[$bgKeys[$i]][1] }
        $l = $script:window.FindName($labels[$i])
        if ($l -and $t[$fgKeys[$i]]) { $l.Foreground = NewBrush $t[$fgKeys[$i]] }
        $s = $script:window.FindName($subs[$i])
        if ($s -and $t[$fgKeys[$i]]) { $s.Foreground = NewBrush ($t[$fgKeys[$i]] + '55') }
    }

    # Cursor bar/label (per-theme CursorColors; the bar is repainted every refresh in
    # Update-CursorSection, so we stash the theme colors for it to reuse).
    $cc  = if ($t.CursorColors) { $t.CursorColors } elseif ($t.FivehColors) { $t.FivehColors } else { @('#065F46','#34D399') }
    $cfg = if ($t.CursorFg)     { $t.CursorFg }     elseif ($t.FivehFg)     { $t.FivehFg }     else { '#34D399' }
    $script:CursorColorsCur = $cc
    $script:AccentCursor = $cfg
    $gc  = if ($t.GrokColors) { $t.GrokColors } elseif ($t.OpusColors) { $t.OpusColors } else { @('#A16207','#FDE68A') }
    $gfg = if ($t.GrokFg)     { $t.GrokFg }     elseif ($t.OpusFg)     { $t.OpusFg }     else { '#FDE68A' }
    $script:GrokColorsCur = $gc
    $script:AccentGrok = $gfg
    $script:AccentFiveh = if ($t.FivehFg) { $t.FivehFg } else { '#38BDF8' }
    $script:AccentWeek  = if ($t.WeekFg)  { $t.WeekFg }  else { '#FB923C' }
    $script:AccentFab   = if ($t.FabFg)   { $t.FabFg }   else { '#C084FC' }
    $script:AccentOpus  = if ($t.OpusFg)  { $t.OpusFg }  else { '#FDE047' }
    foreach ($bn in @('grokWeekBar','grokWeekBarC')) {
        $gb = $script:window.FindName($bn)
        if ($gb) { $gb.Background = New-GradientBrush $gc[0] $gc[1] }
    }
    foreach ($ln in @('grokWeekLabel','grokWeekLabelC')) {
        $gl = $script:window.FindName($ln)
        if ($gl) { $gl.Foreground = NewBrush $gfg }
    }
    $gs = $script:window.FindName('grokWeekSub')
    if ($gs) { $gs.Foreground = NewBrush ($gfg + '55') }
    foreach ($bn in @('reqBar','reqBarC')) {
        $rb = $script:window.FindName($bn)
        if ($rb) { $rb.Background = New-GradientBrush $cc[0] $cc[1] }
    }
    foreach ($ln in @('reqLabel','reqLabelC')) {
        $rl = $script:window.FindName($ln)
        if ($rl) { $rl.Foreground = NewBrush $cfg }
    }
    foreach ($vn in @('claudeVersionText','codexVersionText','cursorVersionText','grokVersionText')) {
        $ve = $script:window.FindName($vn)
        if ($ve) { $ve.Foreground = NewBrush '#7C7C82' }
    }
    # Primary % accents track theme bar hues (refresh re-applies warn/crit).
    foreach ($pair in @(
        @('fivehPct','fivehPctC',$script:AccentFiveh),
        @('weekPct','weekPctC',$script:AccentWeek),
        @('fabPct','fabPctC',$script:AccentFab),
        @('opusPct','opusPctC',$script:AccentOpus),
        @('codexFivehPct','codexFivehPctC',$script:AccentFiveh),
        @('codexWeekPct','codexWeekPctC',$script:AccentWeek),
        @('reqCount','reqCountC',$script:AccentCursor),
        @('grokWeekPct','grokWeekPctC',$script:AccentGrok)
    )) {
        $full = $script:window.FindName($pair[0])
        $comp = $script:window.FindName($pair[1])
        $afg  = $pair[2]
        if ($full) { Set-PctAccentStyle $full $afg }
        if ($comp) { Set-PctAccentStyle $comp $afg -Compact }
    }

    # Sparkline strokes
    $fivehSpark = $script:window.FindName('fivehSpark')
    if ($fivehSpark -and $t.FivehFg) { $fivehSpark.Stroke = NewBrush $t.FivehFg }
    $weekSpark = $script:window.FindName('weekSpark')
    if ($weekSpark -and $t.WeekFg) { $weekSpark.Stroke = NewBrush $t.WeekFg }

    # Sync theme menu checkmarks if the tray built them (WinForms .Checked)
    if ($script:themeItems) {
        foreach ($kv in $script:themeItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $name) }
    }

    # In the notch shell the black silhouette is the panel background.
    if (Get-Command Sync-NotchPanelChrome -ErrorAction SilentlyContinue) { Sync-NotchPanelChrome }
}

# ---------------------------------------------------------------------------
# Set-Section - non-animated visibility/chevron set (startup restore).
# ---------------------------------------------------------------------------
function Set-Section([string]$key, [bool]$expanded) {
    $body = $script:window.FindName($key + 'Body')
    $chev = $script:window.FindName($key + 'Chevron')
    if (-not $body) { return }
    $body.Visibility = if ($expanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    # Segoe MDL2 Assets ChevronDown / ChevronRight.
    if ($chev) { $chev.Text = if ($expanded) { [string][char]0xE70D } else { [string][char]0xE76C } }
}

# ---------------------------------------------------------------------------
# Set-SectionVisible - whole-section visibility for tray Show/Hide.
# Keeps the accordion body state independent; hiding a wrapper hides header+body.
# ---------------------------------------------------------------------------
function Set-SectionVisible([string]$key, [bool]$visible) {
    if (-not $script:window) { return }
    $section = $script:window.FindName($key + 'Section')
    if (-not $section) { return }
    $section.Visibility = if ($visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    Resize-ToContent
}

# ---------------------------------------------------------------------------
# Measure-ContentHeight - forces a layout pass and returns the window's desired
# size (the size the content wants). SizeToContent is Manual, so the window
# height is owned by code (animation or direct set), and this is how we learn
# the target. Width is intrinsic (fixed inner panel) and returned too.
# ---------------------------------------------------------------------------
function Measure-ContentHeight([switch]$SkipArrange) {
    $root = $script:window
    $content = $root.Content
    if ($content) {
        $content.InvalidateMeasure()
        $content.InvalidateArrange()
        $content.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $size = $content.DesiredSize
        if ($size.Width -gt 0 -and $size.Height -gt 0) {
            if (-not $SkipArrange) {
                $content.Arrange([System.Windows.Rect]::new(0, 0, $size.Width, $size.Height))
                $root.UpdateLayout()
            }
            return $size
        }
    }

    $root.UpdateLayout()
    $root.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    return $root.DesiredSize
}

# ---------------------------------------------------------------------------
# Measure-FittedSize - measure the content, then make it fit the monitor.
#
# Measuring is done twice on purpose. The first pass runs with the section
# ScrollViewer unclamped so we learn what the accordion actually wants; if that
# overflows the work area, the overflow is taken out of the scroll region and we
# measure again so the caller gets a size that is really achievable. Returns the
# size to apply to the window.
# ---------------------------------------------------------------------------
function Measure-FittedSize([switch]$SkipArrange) {
    $sv = $script:window.FindName('sectionScroll')
    if (-not $sv) { return (Measure-ContentHeight -SkipArrange:$SkipArrange) }

    # Pass 1: no clamp, so DesiredSize is the true appetite.
    $sv.MaxHeight = [double]::PositiveInfinity
    $size = Measure-ContentHeight -SkipArrange:$SkipArrange

    $wa = Get-WorkArea
    $budget = Get-FitBudget -WorkAreaHeight ($wa.Bottom - $wa.Top)
    $natural = $sv.DesiredSize.Height
    $max = Get-SectionScrollMaxHeight -DesiredTotal $size.Height -ScrollNatural $natural -Budget $budget
    if ($null -eq $max) { return $size }

    # Pass 2: the scroll region gives up the overflow and scrolls it instead.
    $sv.MaxHeight = $max
    $size = Measure-ContentHeight -SkipArrange:$SkipArrange
    $h = Get-ClampedWindowHeight -DesiredTotal $size.Height -Budget $budget
    return [System.Windows.Size]::new($size.Width, $h)
}

# ---------------------------------------------------------------------------
# Resize-ToContent - non-animated: snap Window.Width/Height to the measured
# content size. Called after content-changing refreshes (opus row appears,
# error text) so the box keeps fitting even though SizeToContent is Manual.
# ---------------------------------------------------------------------------
function Resize-ToContent([switch]$SkipDeferred) {
    $root = $script:window
    # The quake strip is monitor-wide by definition, so content-driven sizing
    # would shrink it. Every existing caller (poll completion, section toggle)
    # funnels through here, so this is the one place that has to know.
    if ((Get-Command Test-DropdownMode -ErrorAction SilentlyContinue) -and (Test-DropdownMode)) {
        Resize-QuakeToContent
        return
    }
    if ((Get-Command Test-NotchShell -ErrorAction SilentlyContinue) -and (Test-NotchShell)) {
        # The notch shell owns a fixed stage; it measures the panel itself.
        Update-NotchStageLayout
    } else {
        $size = Measure-FittedSize
        if ($size.Width  -gt 0) { $root.Width  = $size.Width }
        if ($size.Height -gt 0) { $root.Height = $size.Height }
        $root.UpdateLayout()
    }

    if (-not $SkipDeferred -and $root.Dispatcher -and -not $script:ResizeToContentDeferred) {
        $script:ResizeToContentDeferred = $true
        [void]$root.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded,
            [Action]{
                $script:ResizeToContentDeferred = $false
                Resize-ToContent -SkipDeferred
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Toggle-Section - flips a section body, swaps chevron, persists, and animates
# the window height smoothly (DoubleAnimation on Window.HeightProperty).
# SizeToContent is Manual so the animation fully OWNS the height; on Completed
# we clear the animation and write a real Height value so later non-animated
# resizes (Resize-ToContent) can change it.
# ---------------------------------------------------------------------------
function Toggle-Section([string]$key) {
    $body = $script:window.FindName($key + 'Body')
    if (-not $body) { return }
    $root = $script:window

    # Target state = opposite of current visibility.
    $expanded = ($body.Visibility -ne [System.Windows.Visibility]::Visible)

    if ((Get-Command Test-NotchShell -ErrorAction SilentlyContinue) -and (Test-NotchShell)) {
        # Content reflows at once; the silhouette eases to the new height and
        # reveals / hides the difference, instead of resizing the window.
        Set-Section $key $expanded
        # Measure now, and once more after WPF's own layout pass has run.
        Resize-ToContent
        if (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue) { Save-UnifiedState }
        return
    }

    # Start the animation from the height we currently occupy.
    $from = $root.ActualHeight
    if ($from -le 0) { $from = $root.Height }
    if ($from -gt 0) {
        $root.BeginAnimation([System.Windows.Window]::HeightProperty, $null)
        $root.Height = $from
    }

    # Apply the visibility/chevron change, then measure the new desired size
    # without arranging the final layout before the animation starts.
    Set-Section $key $expanded
    $size = Measure-FittedSize -SkipArrange
    $to = $size.Height
    if ($to -le 0) { $to = $root.ActualHeight }
    # Width is intrinsic; pin it now (SizeToContent is Manual).
    if ($size.Width -gt 0) { $root.Width = $size.Width }

    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From     = $from
    $anim.To       = $to
    $anim.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(180))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease

    # On completion, hand the held value back to the real DP so future sets work:
    # clear the animation (BeginAnimation $null) then set Height to the target.
    # FillBehavior=HoldEnd would otherwise pin Height to $to as an animated
    # value and silently swallow later $root.Height = ... assignments.
    $anim.Add_Completed({
        $root.BeginAnimation([System.Windows.Window]::HeightProperty, $null)
        $root.Height = $to
        Resize-ToContent -SkipDeferred
    }.GetNewClosure())

    $root.BeginAnimation([System.Windows.Window]::HeightProperty, $anim)

    if (Get-Command Save-UnifiedState -ErrorAction SilentlyContinue) { Save-UnifiedState }
}

# ---------------------------------------------------------------------------
# Update-ClaudeSection - ports Ui.ps1 Update-UI body (bars, stats, sparklines),
# minus the chrome dot/time (now global). Reads $script:State/$script:Stats.
# ---------------------------------------------------------------------------
function Update-ClaudeSection {
    $identityText = $script:window.FindName('claudeIdentityText')
    if ($identityText) {
        if ($script:ClaudeIdentity -and $script:ClaudeIdentity.Display) {
            $identityText.Text = [string]$script:ClaudeIdentity.Display
            try { $identityText.Foreground = NewBrush '#98989D' } catch { }
        } else {
            $claudeStatus = if ($script:State) { [string]$script:State.Status } else { '' }
            $calm = Get-ProviderCalmEmptyMessage -CliName 'claude' -AuthState $claudeStatus
            if ($calm) {
                $identityText.Text = $calm
            } else {
                $identityText.Text = '--'
            }
            try { $identityText.Foreground = NewBrush '#98989D' } catch { }
        }
    }

    $s = $script:Stats
    if ($s) {
        $script:window.FindName('valText').Text   = ('~{0} all-time' -f (Fmt-Money $s.ValueUSD))
        $script:window.FindName('tokText').Text   = ('{0} in / {1} out' -f (Fmt-Tok $s.InTokens), (Fmt-Tok $s.OutTokens))
        $script:window.FindName('todayText').Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayTok), $s.TodayMsg)
        $afterHoursText = $script:window.FindName('afterHoursText')
        if ($afterHoursText) { $afterHoursText.Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayAfterHoursTok), $s.TodayAfterHoursMsg) }
        $script:window.FindName('lifeText').Text  = ('{0} sessions  {1} msgs' -f $s.Sessions, (Fmt-Tok $s.Messages))
    }

    $d = if ($script:State) { $script:State.Data } else { $null }

    # Stale = last good numbers carried past a failed poll. Dim them and swap
    # every countdown for the fetch time, so they do not pass for live data.
    $stale = ($null -ne $d) -and [bool]$script:State.Stale
    $resetOverride = ''
    $claudeOpacity = 1.0
    if ($stale) {
        $resetOverride = Format-ClaudeStaleReset ([string]$script:State.DataAsOf)
        $claudeOpacity = 0.55
    }
    $claudeBody = $script:window.FindName('claudeBody')
    if ($claudeBody) { $claudeBody.Opacity = $claudeOpacity }

    if ($null -eq $d) {
        Set-SectionBar 'fivehBar' 'fivehPct' 'fivehSub' 'fivehReset' $null $null -AccentFg $script:AccentFiveh
        Set-SectionBar 'weekBar'  'weekPct'  'weekSub'  'weekReset'  $null $null -AccentFg $script:AccentWeek
        Set-SectionBar 'fabBar'   'fabPct'   'fabSub'   'fabReset'   $null $null -AccentFg $script:AccentFab
        Set-CompactBar 'fivehBarC' 'fivehPctC' $null -AccentFg $script:AccentFiveh
        Set-CompactBar 'weekBarC'  'weekPctC'  $null -AccentFg $script:AccentWeek
        Set-CompactBar 'fabBarC'   'fabPctC'   $null -AccentFg $script:AccentFab
        $hd = $script:window.FindName('claudeHeaderDetail'); if ($hd) { $hd.Text = '' }
        return
    }

    $hasAlert = [bool](Get-Command Check-Alert -ErrorAction SilentlyContinue)

    $hd = $script:window.FindName('claudeHeaderDetail')
    if ($hd) {
        if ($resetOverride) { $hd.Text = $resetOverride } else { $hd.Text = Format-Reset $d.five_hour.resets_at }
    }

    Set-SectionBar 'fivehBar' 'fivehPct' 'fivehSub' 'fivehReset' $d.five_hour.utilization $d.five_hour.resets_at -AccentFg $script:AccentFiveh -ResetOverride $resetOverride
    Set-CompactBar 'fivehBarC' 'fivehPctC' $d.five_hour.utilization -AccentFg $script:AccentFiveh
    Set-Spark 'fivehSpark' 'fivehSparkCanvas' 'five_hour' 'fivehSparkRow'
    Set-Spark 'fivehSparkC' 'fivehSparkCanvasC' 'five_hour' 'fivehSparkRowC'
    if ($hasAlert) { Check-Alert 'five_hour' $d.five_hour.utilization }

    Set-SectionBar 'weekBar' 'weekPct' 'weekSub' 'weekReset' $d.seven_day.utilization $d.seven_day.resets_at -AccentFg $script:AccentWeek -ResetOverride $resetOverride
    Set-CompactBar 'weekBarC' 'weekPctC' $d.seven_day.utilization -AccentFg $script:AccentWeek
    Set-Spark 'weekSpark' 'weekSparkCanvas' 'seven_day' 'weekSparkRow'
    Set-Spark 'weekSparkC' 'weekSparkCanvasC' 'seven_day' 'weekSparkRowC'
    if ($hasAlert) { Check-Alert 'seven_day' $d.seven_day.utilization }

    Set-SectionBar 'fabBar' 'fabPct' 'fabSub' 'fabReset' $d.seven_day_fable.utilization $d.seven_day_fable.resets_at -AccentFg $script:AccentFab -ResetOverride $resetOverride
    Set-CompactBar 'fabBarC' 'fabPctC' $d.seven_day_fable.utilization -AccentFg $script:AccentFab
    if ($hasAlert) { Check-Alert 'seven_day_fable' $d.seven_day_fable.utilization }

    if ($d.seven_day_opus) {
        $script:window.FindName('opusRow').Visibility = [System.Windows.Visibility]::Visible
        $oc = $script:window.FindName('opusRowC'); if ($oc) { $oc.Visibility = [System.Windows.Visibility]::Visible }
        Set-SectionBar 'opusBar' 'opusPct' 'opusSub' 'opusReset' $d.seven_day_opus.utilization $d.seven_day_opus.resets_at -AccentFg $script:AccentOpus -ResetOverride $resetOverride
        Set-CompactBar 'opusBarC' 'opusPctC' $d.seven_day_opus.utilization -AccentFg $script:AccentOpus
        if ($hasAlert) { Check-Alert 'seven_day_opus' $d.seven_day_opus.utilization }
    } else {
        $script:window.FindName('opusRow').Visibility = [System.Windows.Visibility]::Collapsed
        $oc = $script:window.FindName('opusRowC'); if ($oc) { $oc.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    $ex = $d.extra_usage
    if ($ex -and $ex.is_enabled -and $ex.monthly_limit) {
        $sym   = if ($ex.currency -eq 'USD') { '$' } else { "$($ex.currency) " }
        $used  = [double]$ex.used_credits  / 100.0
        $limit = [double]$ex.monthly_limit / 100.0
        $script:window.FindName('extraRow').Visibility = [System.Windows.Visibility]::Visible
        $script:window.FindName('extraVal').Text = ('{0}{1:N2} / {0}{2:N0}' -f $sym, $used, $limit)
    } else {
        $script:window.FindName('extraRow').Visibility = [System.Windows.Visibility]::Collapsed
    }
}

# ---------------------------------------------------------------------------
# Update-CodexSection - reads $script:CodexStats; fills codex* elements.
# ---------------------------------------------------------------------------
# Calm empty / missing-CLI / unauth copy. Strangers should see a quiet tray tip,
# not red exception chrome or "run X login" dumps. Test-ProviderAuthFailed still
# decides when to show the line; Resolve-ProviderLoginCli decides install vs login.
function Test-ProviderCliMissing {
    param([Parameter(Mandatory = $true)][string]$CliName)
    if (-not (Get-Command Resolve-ProviderLoginCli -ErrorAction SilentlyContinue)) { return $false }
    return $null -eq (Resolve-ProviderLoginCli $CliName)
}

function Get-ProviderCalmEmptyMessage {
    param(
        [Parameter(Mandatory = $true)][string]$CliName,
        [string]$AuthState
    )
    if (Test-ProviderCliMissing $CliName) {
        return 'Not set up'
    }
    if ([string]$AuthState -eq 'idle') {
        return 'Signed in · idle'
    }
    if (Test-ProviderAuthFailed $AuthState) {
        return 'Not signed in'
    }
    return $null
}

function Set-SectionAuthError {
    param(
        [string]$Name,
        [string]$AuthState,
        [string]$Message,
        [string]$CliName = $null
    )

    $el = $script:window.FindName($Name)
    if (-not $el) { return $false }

    $calm = $null
    if ($CliName) {
        $calm = Get-ProviderCalmEmptyMessage -CliName $CliName -AuthState $AuthState
    } elseif (Test-ProviderAuthFailed $AuthState) {
        $calm = 'Not signed in'
    }

    if ($calm) {
        $el.Text = $calm
        try { $el.Foreground = NewBrush '#98989D' } catch { }
        $el.Visibility = [System.Windows.Visibility]::Visible
        return $true
    }

    $el.Text = ''
    $el.Visibility = [System.Windows.Visibility]::Collapsed
    return $false
}

function Get-OverlayStatNote {
    # Hashtable and PSCustomObject note reader; keeps 0% distinct from missing.
    param($Obj, [string]$Name)
    if ($null -eq $Obj -or -not $Name) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        foreach ($k in @($Obj.Keys)) {
            if ([string]$k -eq $Name) { return $Obj[$k] }
        }
        return $null
    }
    if ($Obj.PSObject -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }
    return $null
}

function Update-CodexSection {
    Set-SectionAuthError 'codexErrText' $script:CodexAuthState $script:CodexErrMsg -CliName 'codex' | Out-Null

    $s = $script:CodexStats
    if (-not $s) {
        foreach ($n in @('codexFivehRow','codexFivehRowC','codexFivehSparkRow','codexFivehSparkRowC')) {
            $el = $script:window.FindName($n); if ($el) { $el.Visibility = [System.Windows.Visibility]::Collapsed }
        }
        Set-SectionBar 'codexWeekBar' 'codexWeekPct' 'codexWeekSub' 'codexWeekReset' $null $null -AccentFg $script:AccentWeek
        Set-CompactBar 'codexWeekBarC' 'codexWeekPctC' $null -AccentFg $script:AccentWeek
        Set-Spark 'codexWeekSpark' 'codexWeekSparkCanvas' 'codex_seven_day' 'codexWeekSparkRow'
        Set-Spark 'codexWeekSparkC' 'codexWeekSparkCanvasC' 'codex_seven_day' 'codexWeekSparkRowC'
        $cr = $script:window.FindName('codexResetsText'); if ($cr) { $cr.Text = '--' }
        $tt = $script:window.FindName('codexTokText'); if ($tt) { $tt.Text = '--' }
        $cv = $script:window.FindName('codexValText'); if ($cv) { $cv.Text = '--' }
        $ct = $script:window.FindName('codexTodayText'); if ($ct) { $ct.Text = '--' }
        $ca = $script:window.FindName('codexAfterHoursText'); if ($ca) { $ca.Text = '--' }
        $cs = $script:window.FindName('codexSessText'); if ($cs) { $cs.Text = '--' }
        $chd = $script:window.FindName('codexHeaderDetail'); if ($chd) { $chd.Text = '' }
        return
    }
    $fiveHourPct = Get-OverlayStatNote $s 'FiveHourPct'
    $fiveHourResetsAt = Get-OverlayStatNote $s 'FiveHourResetsAt'
    $weekPct = Get-OverlayStatNote $s 'WeekPct'
    $weekResetsAt = Get-OverlayStatNote $s 'WeekResetsAt'
    $fivehVis = if ($null -ne $fiveHourPct) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    foreach ($n in @('codexFivehRow','codexFivehRowC')) {
        $el = $script:window.FindName($n); if ($el) { $el.Visibility = $fivehVis }
    }
    if ($null -ne $fiveHourPct) {
        Set-SectionBar 'codexFivehBar' 'codexFivehPct' 'codexFivehSub' 'codexFivehReset' $fiveHourPct $fiveHourResetsAt -AccentFg $script:AccentFiveh
        Set-CompactBar 'codexFivehBarC' 'codexFivehPctC' $fiveHourPct -AccentFg $script:AccentFiveh
        Set-Spark 'codexFivehSpark' 'codexFivehSparkCanvas' 'codex_five_hour' 'codexFivehSparkRow'
        Set-Spark 'codexFivehSparkC' 'codexFivehSparkCanvasC' 'codex_five_hour' 'codexFivehSparkRowC'
    } else {
        # No live 5h window: hide spark rows even if history still has samples.
        foreach ($n in @('codexFivehSparkRow','codexFivehSparkRowC')) {
            $el = $script:window.FindName($n); if ($el) { $el.Visibility = [System.Windows.Visibility]::Collapsed }
        }
    }
    Set-SectionBar 'codexWeekBar' 'codexWeekPct' 'codexWeekSub' 'codexWeekReset' $weekPct $weekResetsAt -AccentFg $script:AccentWeek
    # Compact must track full WEEKLY %. Prefer live WeekPct; if compact still
    # shows '--' while full has N%, re-paint compact from the full label.
    $weekForCompact = $weekPct
    if ($null -eq $weekForCompact) {
        $fullPctEl = $script:window.FindName('codexWeekPct')
        if ($fullPctEl -and [string]$fullPctEl.Text -match '^(\d+)%$') {
            $weekForCompact = [double]$Matches[1]
        }
    }
    Set-CompactBar 'codexWeekBarC' 'codexWeekPctC' $weekForCompact -AccentFg $script:AccentWeek
    Set-Spark 'codexWeekSpark' 'codexWeekSparkCanvas' 'codex_seven_day' 'codexWeekSparkRow'
    Set-Spark 'codexWeekSparkC' 'codexWeekSparkCanvasC' 'codex_seven_day' 'codexWeekSparkRowC'
    $chd = $script:window.FindName('codexHeaderDetail'); if ($chd) { $chd.Text = Format-Reset $weekResetsAt }
    $codexResetsText = $script:window.FindName('codexResetsText')
    if ($codexResetsText) {
        if ($null -ne $s.ResetsAvailable) {
            $codexResetsText.Text = ('{0} available' -f [int]$s.ResetsAvailable)
        } else {
            $codexResetsText.Text = '--'
        }
    }
    $script:window.FindName('codexValText').Text   = ('~{0} all-time' -f (Fmt-Money $s.ValueUSD))
    $script:window.FindName('codexTokText').Text   = ('{0} in / {1} out' -f (Fmt-Tok $s.InTokens), (Fmt-Tok $s.OutTokens))
    $script:window.FindName('codexTodayText').Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayTok), $s.TodayMsg)
    $codexAfterHoursText = $script:window.FindName('codexAfterHoursText')
    if ($codexAfterHoursText) { $codexAfterHoursText.Text = ('{0} tok  {1} msgs' -f (Fmt-Tok $s.TodayAfterHoursTok), $s.TodayAfterHoursMsg) }
    $script:window.FindName('codexSessText').Text  = ('{0} sessions  {1} msgs' -f $s.Sessions, (Fmt-Tok $s.Messages))
}

# ---------------------------------------------------------------------------
# Update-CursorSection - ports cursor-overlay.ps1 Update-UI body (minus chrome
# dot/time), renamed dup elements + namespaced error/fetch vars.
# ---------------------------------------------------------------------------
function Update-GrokResetDisplay {
    $label = $script:window.FindName('grokResetsText')
    if (-not $label) { return }
    $usage = $script:GrokUsage
    $label.Text = '--'
    $label.ToolTip = 'One-time usage reset availability could not be verified.'
    if ($script:GrokAuthState -ne 'ok' -or -not $usage -or $usage.ResetStatus -ne 'ok' -or $null -eq $usage.ResetsAvailable) { return }
    $label.Text = ('{0} available' -f $usage.ResetsAvailable)
    $label.ToolTip = 'One-time usage resets. Redeem on the Grok Usage page.'
    if ($usage.ResetExpiresAt) {
        $end = [datetimeoffset]$usage.ResetExpiresAt
        if ($end -le [datetimeoffset]::Now) {
            $label.Text = '--'
            $label.ToolTip = 'Reset availability needs refreshing after expiry.'
        } else {
            $label.ToolTip += (' Earliest expires {0:MMM d, yyyy h:mm tt}.' -f $end.LocalDateTime)
        }
    }
}

function Update-GrokSection {
    Update-GrokResetDisplay
    Set-SectionAuthError 'grokErrText' $script:GrokAuthState $script:GrokErrMsg -CliName 'grok' | Out-Null

    $s = $script:GrokUsage
    if (-not $s) {
        Set-SectionBar 'grokWeekBar' 'grokWeekPct' 'grokWeekSub' 'grokWeekReset' $null $null -AccentFg $script:AccentGrok
        Set-CompactBar 'grokWeekBarC' 'grokWeekPctC' $null -AccentFg $script:AccentGrok
        Set-Spark 'grokWeekSpark' 'grokWeekSparkCanvas' 'grok_seven_day' 'grokWeekSparkRow'
        Set-Spark 'grokWeekSparkC' 'grokWeekSparkCanvasC' 'grok_seven_day' 'grokWeekSparkRowC'
        $pt = $script:window.FindName('grokPlanText'); if ($pt) { Set-GrokProductUsageVisual $pt '--' $script:AccentGrok }
        $pp = $script:window.FindName('grokPrepaidText'); if ($pp) { $pp.Text = '--' }
        $hd = $script:window.FindName('grokHeaderDetail'); if ($hd) { $hd.Text = '' }
        return
    }
    $weekPct = Get-OverlayStatNote $s 'WeekPct'
    $weekResetsAt = Get-OverlayStatNote $s 'WeekResetsAt'
    $prepaid = Get-OverlayStatNote $s 'PrepaidBalance'
    $productText = Get-OverlayStatNote $s 'ProductUsageText'
    $planType = Get-OverlayStatNote $s 'PlanType'
    Set-SectionBar 'grokWeekBar' 'grokWeekPct' 'grokWeekSub' 'grokWeekReset' $weekPct $weekResetsAt -AccentFg $script:AccentGrok
    Set-CompactBar 'grokWeekBarC' 'grokWeekPctC' $weekPct -AccentFg $script:AccentGrok
    Set-Spark 'grokWeekSpark' 'grokWeekSparkCanvas' 'grok_seven_day' 'grokWeekSparkRow'
    Set-Spark 'grokWeekSparkC' 'grokWeekSparkCanvasC' 'grok_seven_day' 'grokWeekSparkRowC'
    $hd = $script:window.FindName('grokHeaderDetail')
    if ($hd) { $hd.Text = Format-Reset $weekResetsAt }
    $pt = $script:window.FindName('grokPlanText')
    if ($pt) {
        $chipText = if ($productText) { [string]$productText } elseif ($planType) { [string]$planType } else { '--' }
        Set-GrokProductUsageVisual $pt $chipText $script:AccentGrok
    }
    $pp = $script:window.FindName('grokPrepaidText')
    if ($pp) {
        # Show 0.00 prepaid; only blank when the field is absent.
        $pp.Text = if ($null -ne $prepaid -and [string]$prepaid -ne '') { [string]$prepaid } else { '--' }
    }
}

function Update-CursorSection {
    # MODELS / OTHER / on-demand from usage-summary (Plan & Usage).
    # Do not paint from legacy usage.gpt-4 numRequests/maxRequestUsage (null → 0/0).
    $plan = Get-CursorPlanUsageFromSummary $script:SummaryData
    $hasBar = ($null -ne $plan.BarPercent)
    $pct = if ($hasBar) { [math]::Min(100, [math]::Round([double]$plan.BarPercent)) } else { 0 }
    # Prefer bar % for overage so a mismatched used/limit (e.g. 2000/2000) does not flash "over".
    $over = $false
    if ($hasBar) {
        $over = [double]$plan.BarPercent -gt 100
    } elseif (($null -ne $plan.Used) -and ($null -ne $plan.Limit) -and ([double]$plan.Limit -gt 0)) {
        $over = [double]$plan.Used -gt [double]$plan.Limit
    }

    $bar = $script:window.FindName('reqBar')
    $barC = $script:window.FindName('reqBarC')
    if ($hasBar) {
        Set-BarWidth $bar ([math]::Min($script:BarTrackWidth, [math]::Round($pct / 100.0 * $script:BarTrackWidth)))
        Set-BarWidth $barC ([math]::Min($script:CompactBarWidth, [math]::Round($pct / 100.0 * $script:CompactBarWidth)))
    } else {
        Set-BarWidth $bar 0
        Set-BarWidth $barC 0
    }

    $pill = $script:window.FindName('overPill')
    if ($hasBar -and $over) {
        if ($bar) { $bar.Background = New-GradientBrush '#78350F' '#FF9F0A' }
        if ($barC) { $barC.Background = New-GradientBrush '#78350F' '#FF9F0A' }
        if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Visible }
    } else {
        $cc = if ($script:CursorColorsCur) { $script:CursorColorsCur } else { @('#065F46','#34D399') }
        if ($bar) { $bar.Background = New-GradientBrush $cc[0] $cc[1] }
        if ($barC) { $barC.Background = New-GradientBrush $cc[0] $cc[1] }
        if ($pill) { $pill.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    # Full view: big % like Codex WEEKLY; used/limit only in sub when it agrees with bar.
    $countText = Format-CursorPlanCountText $plan
    $cursorAccent = if ($script:AccentCursor) { $script:AccentCursor } else { '#34D399' }
    $rc = $script:window.FindName('reqCount')
    $sub = $script:window.FindName('reqSub')
    if ($rc) {
        if ($hasBar) {
            $rc.Text = ('{0}%' -f $pct)
            Set-PctAccentStyle $rc (Resolve-PctAccentFg $pct $cursorAccent)
        } else {
            $rc.Text = '--'
            Set-PctAccentStyle $rc '#F5F5F7'
        }
    }
    if ($sub) {
        if ($hasBar -and $countText -match '/') {
            Set-BarSubText $sub $countText
        } else {
            Set-BarSubText $sub 'used'
        }
    }
    $rcc = $script:window.FindName('reqCountC')
    if ($rcc) {
        $rcc.Text = $countText
        if ($hasBar) {
            Set-PctAccentStyle $rcc (Resolve-PctAccentFg $pct $cursorAccent) -Compact
        } else {
            Set-PctAccentStyle $rcc '#F5F5F7' -Compact
        }
    }
    $rr = $script:window.FindName('reqReset')
    if ($rr) {
        $rr.Text = if ($plan.BillingCycleEnd) { Format-PanelReset $plan.BillingCycleEnd } else { '' }
    }

    $otherText = '--'
    if ($null -ne $plan.ApiPercent) {
        $otherText = ('{0:0}%' -f [double]$plan.ApiPercent)
    }
    foreach ($n in @('otherModelsText','otherModelsTextC')) {
        $el = $script:window.FindName($n)
        if ($el) { $el.Text = $otherText }
    }

    # On-demand from usage-summary (enabled + used)
    $od = $script:window.FindName('onDemandText')
    if ($od) {
        if (Test-ProviderAuthFailed $script:AuthState) {
            $od.FontSize = 11
            $od.Text = 'Not signed in'
            $od.Foreground = NewBrush '#98989D'
        } else {
            $od.FontSize = 12
            if (($null -ne $plan.OnDemandEnabled) -and (-not $plan.OnDemandEnabled)) {
                $od.Text = 'Off'
                $od.Foreground = NewBrush '#8E8E93'
            } elseif ($null -ne $plan.OnDemandUsedCents) {
                $dollars = [double]$plan.OnDemandUsedCents / 100.0
                $od.Text = ('${0:N2}' -f $dollars)
                $od.Foreground = if ($dollars -gt 0) { NewBrush '#FF9F0A' } else { NewBrush '#8E8E93' }
            } else {
                $od.Text = '--'
                $od.Foreground = NewBrush '#8E8E93'
            }
        }
    }

    # Edit/model stats from the Cursor analytics API (30-day rolling window).
    # When LocalData is null (405/403), hide the whole block so compact/full
    # are not a wall of "--".
    $l = $script:LocalData
    $analytics = $script:window.FindName('cursorAnalyticsBlock')
    if ($l) {
        if ($analytics) { $analytics.Visibility = [System.Windows.Visibility]::Visible }
        $et = $script:window.FindName('editsText'); if ($et) { $et.Text = ('{0} (30d)' -f (Fmt-Num $l.edits30d)) }
        $ct = $script:window.FindName('cursorTodayText'); if ($ct) { $ct.Text = ('{0} edits' -f (Fmt-Num $l.editsToday)) }
        $cm = $script:window.FindName('cursorModelText')
        if ($cm) {
            if ($l.topModel) {
                $mn = $l.topModel -replace 'claude-','cl-' -replace 'composer-','cmp-' -replace '-latest',''
                $cm.Text = "$mn ($($l.topPct)%)"
            } else {
                $cm.Text = '--'
            }
        }
        $cs = $script:window.FindName('cursorSessText'); if ($cs) { $cs.Text = ('{0} lines' -f (Fmt-Num $l.linesAccepted)) }
    } else {
        if ($analytics) { $analytics.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    # Compact header detail: on-demand cost takes over (amber) the moment Cursor
    # reports any on-demand spend - that's the number you want when you're paying.
    # Below that threshold it shows the billing-cycle reset instead.
    $uhd = $script:window.FindName('cursorHeaderDetail')
    if ($uhd) {
        $sum = $script:SummaryData
        $odDollars = 0.0
        $odOn = $true
        if ($null -ne $plan.OnDemandEnabled) { $odOn = [bool]$plan.OnDemandEnabled }
        if ($odOn -and ($null -ne $plan.OnDemandUsedCents)) {
            $odDollars = [double]$plan.OnDemandUsedCents / 100.0
        }
        if ($odOn -and $odDollars -gt 0) {
            $uhd.Text = ('${0:N2}' -f $odDollars); $uhd.Foreground = NewBrush '#FF9F0A'
        } elseif ($sum -and $sum.billingCycleEnd) {
            $uhd.Text = Format-Reset $sum.billingCycleEnd; $uhd.Foreground = NewBrush '#7B9EC4'
        } else {
            $uhd.Text = ''
        }
    }

    Set-Spark 'cursorReqSpark' 'cursorReqSparkCanvas' 'cursor_requests' 'cursorReqSparkRow'
    Set-Spark 'cursorReqSparkC' 'cursorReqSparkCanvasC' 'cursor_requests' 'cursorReqSparkRowC'
}

# ---------------------------------------------------------------------------
# Update-AllSections - chrome dot/time + the three section renderers + tray text.
# ---------------------------------------------------------------------------
function Test-ClaudeSectionVisible {
    # Show/Hide Claude: Cfg.Sections['claude'] false means Claude chrome must stay quiet.
    if (-not $script:Cfg -or -not $script:Cfg.Sections) { return $true }
    $sections = $script:Cfg.Sections
    if ($sections -is [System.Collections.IDictionary]) {
        if ($sections.Contains('claude')) { return [bool]$sections['claude'] }
        return $true
    }
    $prop = $sections.PSObject.Properties['claude']
    if ($prop) { return [bool]$prop.Value }
    return $true
}

function Update-AllSections {
    $dot  = $script:window.FindName('statusDot')
    $time = $script:window.FindName('timeText')
    $status = if ($script:State) { $script:State.Status } else { 'init' }
    $statuses = @{
        claude = $status
        codex  = $script:CodexAuthState
        cursor = $script:AuthState
        grok   = $script:GrokAuthState
    }
    # Worst status among the sections the user enabled. A hidden provider -
    # Claude included - never surfaces its auth/stale/error in the top chrome.
    $enabled = if ($script:Cfg) { $script:Cfg.Sections } else { $null }
    $worst = Get-WorstProviderStatus -Status $statuses -Enabled $enabled
    $chromeStatus = $worst.Status
    if ($dot) { $dot.Fill = NewBrush (Get-StatusDotColor $chromeStatus) }
    if ($time -and $script:State) {
        $busy = if ($status -eq 'refreshing') { [string]$script:State.Message } else { '' }
        $time.Text = Get-ChromeStatusText -Status $chromeStatus -Provider $worst.Provider `
            -LastFetch $script:State.LastFetch -Busy $busy
    }
    Set-SectionStatusDots $statuses

    Update-ClaudeSection
    Update-CodexSection
    Update-CursorSection
    Update-GrokSection
    if (Get-Command Update-ProviderVersionLabels -ErrorAction SilentlyContinue) { Update-ProviderVersionLabels }

    if (Get-Command Sync-CompactModeBodies -ErrorAction SilentlyContinue) { Sync-CompactModeBodies }

    # NOTE: Resize-ToContent is deliberately NOT called here. This runs on the
    # 30s tick timer, and a full-tree Measure every 30s is wasted work (content
    # height only changes on the 180s data poll or a section toggle). Callers
    # that change content size (poll-completion handler, startup restore) invoke
    # Resize-ToContent explicitly; Toggle-Section resizes via its animation.

    if ($script:notify -and $script:State -and $script:State.Data) {
        $cd = $script:State.Data
        $identity = if ($script:ClaudeIdentity -and $script:ClaudeIdentity.Email) { [string]$script:ClaudeIdentity.Email } else { 'Claude' }
        $text = ('AI  {0}  5h {1:0}%  Wk {2:0}%' -f $identity, [double]$cd.five_hour.utilization, [double]$cd.seven_day.utilization)
        if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
        $script:notify.Text = $text
    }

    if (Get-Command Update-QuakeView -ErrorAction SilentlyContinue) { Update-QuakeView }

    # Card status pills, "Live" state, limit badges and two-tone stat values.
    if (Get-Command Update-PanelChrome -ErrorAction SilentlyContinue) {
        try { Update-PanelChrome -Statuses $statuses -ChromeStatus $chromeStatus } catch { }
    }
}

# One quiet dot per section header, so a single provider failing no longer
# hides the others' health behind the chrome dot. The tooltip carries the
# detail; the dot itself costs no row height.
function Set-SectionStatusDots($Statuses) {
    $claudeMsg = ''
    $claudeFetch = ''
    if ($script:State) { $claudeMsg = $script:State.Message; $claudeFetch = $script:State.LastFetch }
    $detail = @{
        claude = @{ Message = $claudeMsg;          LastFetch = $claudeFetch }
        codex  = @{ Message = $script:CodexErrMsg;  LastFetch = '' }
        cursor = @{ Message = $script:CursorErrMsg; LastFetch = $script:CursorLastFetch }
        grok   = @{ Message = $script:GrokErrMsg;   LastFetch = '' }
    }
    foreach ($key in $script:StatusProviderOrder) {
        $el = $script:window.FindName($key + 'StatusDot')
        if (-not $el) { continue }
        $st = Get-StatusMapValue $Statuses $key
        $el.Fill = NewBrush (Get-StatusDotColor $st)
        $el.ToolTip = Get-SectionStatusTip -Status $st -Message $detail[$key].Message -LastFetch $detail[$key].LastFetch
    }
}
