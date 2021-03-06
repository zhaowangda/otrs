# --
# Copyright (C) 2001-2018 OTRS AG, https://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Console::Command::Admin::Config::FixInvalid;

use strict;
use warnings;

use parent qw(Kernel::System::Console::BaseCommand);
use Kernel::System::VariableCheck qw( :all );

our @ObjectDependencies = (
    'Kernel::System::Main',
    'Kernel::System::SysConfig',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Attempt to fix invalid system configuration.');
    $Self->AddOption(
        Name        => 'non-interactive',
        Description => "Attempt to fix it without user interaction.",
        Required    => 0,
        HasValue    => 0,
    );

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $NonInteractive = $Self->GetOption('non-interactive') || 0;

    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');

    my @InvalidSettings = $SysConfigObject->ConfigurationInvalidList(
        Undeployed => 1,
        NoCache    => 1,
    );

    if ( !scalar @InvalidSettings ) {
        $Self->Print("<green>All settings are valid.</green>\n");
        $Self->Print("\n<green>Done.</green>\n");
        return $Self->ExitCodeOk();
    }

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    my @FixedSettings;
    my @NotFixedSettings;

    SETTING:
    for my $SettingName (@InvalidSettings) {
        my %Setting = $SysConfigObject->SettingGet(
            Name => $SettingName,
        );

        # Skip settings that are not related to the Entities.
        if ( !$Setting{XMLContentRaw} =~ m{ValueType="Entity"} ) {
            $Self->Print("\n<red>$SettingName is not an entity value type!</red>\n");
            push @NotFixedSettings, $SettingName;
            next SETTING;
        }

        my $EntityType;
        $Setting{XMLContentRaw} =~ m{ValueEntityType="(.*?)"};
        $EntityType = $1;

        # Skip settings without ValueEntityType.
        if ( !$EntityType ) {
            $Self->Print("\n<red>System was unable to determine ValueEntityType for $SettingName!</red>\n");
            push @NotFixedSettings, $SettingName;
            next SETTING;
        }

        # Check if Entity module exists.
        my $Loaded = $MainObject->Require(
            "Kernel::System::SysConfig::ValueType::Entity::$EntityType",
            Silent => 1,
        );

        if ( !$Loaded ) {
            $Self->Print("\n<red>Kernel::System::SysConfig::ValueType::Entity::$EntityType not found!</red>\n");
            push @NotFixedSettings, $SettingName;
            next SETTING;
        }

        my $Object = $Kernel::OM->Get(
            "Kernel::System::SysConfig::ValueType::Entity::$EntityType"
        );

        my @List = $Object->EntityValueList();

        if ( !scalar @List ) {
            $Self->Print("\n<red>$EntityType list is empty!</red>\n");
            push @NotFixedSettings, $SettingName;
            next SETTING;
        }

        my $Value;
        if ($NonInteractive) {

            # Take first option available.
            $Value = $List[0];
        }
        else {
            # Ask user.
            $Self->Print("\n<yellow>$SettingName is invalid, select one of the choices below:</yellow>\n");

            my $Index = 1;
            for my $Item (@List) {
                $Self->Print("    [$Index] $Item\n");
                $Index++;
            }

            my $SelectedIndex;
            while (
                !$SelectedIndex
                || !IsPositiveInteger($SelectedIndex)
                || $SelectedIndex > scalar @List
                )
            {
                print "\nYour choice: ";
                $SelectedIndex = <STDIN>;    ## no critic

                # Remove white space
                $SelectedIndex =~ s{\s}{}smx;
            }

            $Value = $List[ $SelectedIndex - 1 ];
        }

        my $ExclusiveLockGUID = $SysConfigObject->SettingLock(
            Name   => $SettingName,
            Force  => 1,
            UserID => 1,
        );
        if ( !$ExclusiveLockGUID ) {
            $Self->Print("\n<red>System was not able to lock the setting $SettingName!</red>\n");
            push @NotFixedSettings, $SettingName;
            next SETTING;
        }

        my %Update = $SysConfigObject->SettingUpdate(
            Name              => $SettingName,
            IsValid           => 1,
            EffectiveValue    => $Value,
            ExclusiveLockGUID => $ExclusiveLockGUID,
            UserID            => 1,
        );

        if ( !$Update{Success} ) {
            $Self->Print("\n<red>System was not able to update the setting $SettingName!</red>\n");
            push @NotFixedSettings, $SettingName;
            next SETTING;
        }

        if ($NonInteractive) {
            $Self->Print("\n<green>Auto-corrected setting: $SettingName</green>");
        }

        push @FixedSettings, $SettingName;
    }

    if ( scalar @FixedSettings ) {

        my %Result = $SysConfigObject->ConfigurationDeploy(
            Comments      => "Automatically fixed settings",
            NoValidation  => 1,
            UserID        => 1,
            Force         => 1,
            DirtySettings => \@FixedSettings,
        );

        if ( !$Result{Success} ) {
            $Self->Print("\n<red>Deployment failed.</red>\n");
            return $Self->ExitCodeError();
        }

        $Self->Print("\n<green>Deployment successful.</green>\n");
    }

    if ( scalar @NotFixedSettings ) {
        $Self->Print(
            "\n<red>Following settings were not fixed:\n" .
                join( ",\n", map {"  - $_"} @NotFixedSettings ) . "</red>\n"
        );
        return $Self->ExitCodeError();
    }

    $Self->Print("\n<green>Done.</green>\n");

    return $Self->ExitCodeOk();
}

1;
