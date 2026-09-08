// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Windows.Media;

namespace System.Windows.Controls;

/// <summary>
/// PortableVisualOwnerKind decides whether the portable pointer path can target an element or
/// walks past it to the nearest content ancestor (see
/// WpfPortablePresentationSourceBridge.TryNormalizePointerInputOwner). Panels and Borders paint
/// their own geometry once they have a Background, which in WPF makes them genuine hit-test
/// targets - Background="Transparent" is THE idiom for an invisible-but-hit-testable element.
/// These previously reported PointerInfrastructure unconditionally, so a transparent overlay panel
/// laid over other content could never receive input: the pointer resolved to whatever content
/// element enclosed it instead.
/// </summary>
public sealed class PortableVisualOwnerKindTests
{
    private static PortableVisualOwnerKind KindOf(object element) =>
        ((IPortableVisualOwnerHost)element).PortableVisualOwnerKind;

    [Fact]
    public void Panel_WithoutBackground_IsPointerInfrastructure()
    {
        Assert.Equal(PortableVisualOwnerKind.PointerInfrastructure, KindOf(new Canvas()));
        Assert.Equal(PortableVisualOwnerKind.PointerInfrastructure, KindOf(new Grid()));
        Assert.Equal(PortableVisualOwnerKind.PointerInfrastructure, KindOf(new StackPanel()));
    }

    [Fact]
    public void Panel_WithTransparentBackground_IsContent()
    {
        Assert.Equal(PortableVisualOwnerKind.Content, KindOf(new Canvas { Background = Brushes.Transparent }));
        Assert.Equal(PortableVisualOwnerKind.Content, KindOf(new Grid { Background = Brushes.Transparent }));
    }

    [Fact]
    public void Panel_WithOpaqueBackground_IsContent()
    {
        Assert.Equal(PortableVisualOwnerKind.Content, KindOf(new StackPanel { Background = Brushes.White }));
    }

    [Fact]
    public void Border_WithoutBrushes_IsPointerInfrastructure()
    {
        Assert.Equal(PortableVisualOwnerKind.PointerInfrastructure, KindOf(new Border()));
    }

    [Fact]
    public void Border_WithTransparentBackground_IsContent()
    {
        Assert.Equal(PortableVisualOwnerKind.Content, KindOf(new Border { Background = Brushes.Transparent }));
    }

    [Fact]
    public void Border_WithBorderBrushOnly_IsContent()
    {
        Assert.Equal(PortableVisualOwnerKind.Content, KindOf(new Border { BorderBrush = Brushes.Black }));
    }

    [Fact]
    public void BareDecorator_StaysPointerInfrastructure()
    {
        // A Decorator that is not a Border paints nothing of its own, so it must keep passing the
        // pointer through - this is the behaviour the Border override must not generalise away.
        Assert.Equal(PortableVisualOwnerKind.PointerInfrastructure, KindOf(new Decorator()));
    }
}
