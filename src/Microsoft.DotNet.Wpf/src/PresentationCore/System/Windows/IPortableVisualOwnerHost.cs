// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace System.Windows
{
    public interface IPortableVisualOwnerHost
    {
        object PortableVisualParent { get; }

        bool IsPortableInputEnabled { get; }

        PortableVisualOwnerKind PortableVisualOwnerKind { get; }

        /// <summary>
        /// Whether the pointer can hit this owner at all, as opposed to passing straight through
        /// it (WPF's UIElement.IsHitTestVisible). This is deliberately narrower than
        /// <see cref="IsPortableInputEnabled"/>, which also folds in IsEnabled and IsVisible: a
        /// DISABLED element is still hit-testable in WPF and must keep swallowing input rather
        /// than letting it reach whatever sits behind it, whereas an element with
        /// IsHitTestVisible=false can never be a pointer target and must not even be reported as a
        /// candidate - the portable hit test hands owners back in a fixed-size buffer, so purely
        /// decorative visuals that report themselves here would starve it and truncate away the
        /// real targets behind them.
        ///
        /// Defaults to <see cref="IsPortableInputEnabled"/> so existing implementors keep working.
        /// </summary>
        bool IsPortableHitTestVisible => IsPortableInputEnabled;
    }
}
