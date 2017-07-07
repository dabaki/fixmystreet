package FixMyStreet::Script::UpdateAllReports;

use strict;
use warnings;

use FixMyStreet;
use FixMyStreet::DB;

use File::Path ();
use File::Slurp;
use JSON::MaybeXS;
use List::MoreUtils qw(zip);
use List::Util qw(sum);

my $fourweeks = 4*7*24*60*60;

# Age problems from when they're confirmed, except on Zurich
# where they appear as soon as they're created.
my $age_column = 'confirmed';
if ( FixMyStreet->config('BASE_URL') =~ /zurich|zueri/ ) {
    $age_column = 'created';
}

sub generate {
    my $problems = FixMyStreet::DB->resultset('Problem')->search(
        {
            state => [ FixMyStreet::DB::Result::Problem->visible_states() ],
        },
        {
            columns => [
                'id', 'bodies_str', 'state', 'areas', 'cobrand',
                { duration => { extract => "epoch from current_timestamp-lastupdate" } },
                { age      => { extract => "epoch from current_timestamp-$age_column"  } },
            ]
        }
    );
    $problems = $problems->cursor; # Raw DB cursor for speed

    my ( %fixed, %open );
    my @cols = ( 'id', 'bodies_str', 'state', 'areas', 'cobrand', 'duration', 'age' );
    while ( my @problem = $problems->next ) {
        my %problem = zip @cols, @problem;
        my @bodies;
        my $cobrand = $problem{cobrand};

        if ( !$problem{bodies_str} ) {
            # Problem was not sent to any bodies, add to all areas
            @bodies = grep { $_ } split( /,/, $problem{areas} );
            $problem{bodies} = 0;
        } else {
            # Add to bodies it was sent to
            @bodies = split( /,/, $problem{bodies_str} );
            $problem{bodies} = scalar @bodies;
        }
        foreach my $body ( @bodies ) {
            my $duration_str = ( $problem{duration} > 2 * $fourweeks ) ? 'old' : 'new';
            my $type = ( $problem{duration} > 2 * $fourweeks )
                ? 'unknown'
                : ($problem{age} > $fourweeks ? 'older' : 'new');
            if (FixMyStreet::DB::Result::Problem->fixed_states()->{$problem{state}} || FixMyStreet::DB::Result::Problem->closed_states()->{$problem{state}}) {
                # Fixed problems are either old or new
                $fixed{$body}{$duration_str}++;
                $fixed{$cobrand}{$body}{$duration_str}++;
            } else {
                # Open problems are either unknown, older, or new
                $open{$body}{$type}++;
                $open{$cobrand}{$body}{$type}++;
            }
        }
    }

    my $body = encode_json( {
        fixed => \%fixed,
        open  => \%open,
    } );

    File::Path::mkpath( FixMyStreet->path_to( '../data/' )->stringify );
    File::Slurp::write_file( FixMyStreet->path_to( '../data/all-reports.json' )->stringify, \$body );
}

sub generate_dashboard {
    my %data;

    my $now = DateTime->now;
    my $min_confirmed = FixMyStreet::DB->resultset('Problem')->search({
        state => [ FixMyStreet::DB::Result::Problem->visible_states() ],
    }, {
        select => [ { min => 'confirmed' } ],
        as => [ 'confirmed' ],
    })->first->confirmed;

    my ($group_by, @problem_periods);
    if (DateTime::Duration->compare($now - $min_confirmed, DateTime::Duration->new(months => 1)) < 0) {
        $group_by = 'day';
        while ($min_confirmed < $now) {
            push @problem_periods, $min_confirmed->day;
            $min_confirmed->add(days => 1);
        }
    } elsif (DateTime::Duration->compare($now - $min_confirmed, DateTime::Duration->new(years => 1)) < 0) {
        $group_by = 'month';
        while ($min_confirmed < $now) {
            push @problem_periods, $min_confirmed->month_abbr;
            $min_confirmed->add(months => 1);
        }
    } else {
        $group_by = 'year';
        @problem_periods = ($min_confirmed->year..$now->year);
    }

    my %problems_reported_by_period = stuff_by_day_or_year(
        $group_by, 'Problem',
        state => [ FixMyStreet::DB::Result::Problem->visible_states() ],
    );
    my %problems_fixed_by_period = stuff_by_day_or_year(
        $group_by, 'Problem',
        state => [ FixMyStreet::DB::Result::Problem->fixed_states() ],
    );

    my (@problems_reported_by_period, @problems_fixed_by_period);
    foreach (@problem_periods) {
        push @problems_reported_by_period, ($problems_reported_by_period[-1]||0) + ($problems_reported_by_period{$_}||0);
        push @problems_fixed_by_period, ($problems_fixed_by_period[-1]||0) + ($problems_fixed_by_period{$_}||0);
    }
    $data{problem_periods} = \@problem_periods;
    $data{problems_reported_by_period} = \@problems_reported_by_period;
    $data{problems_fixed_by_period} = \@problems_fixed_by_period;

    my %last_seven_days = (
        problems => [],
        updated => [],
        fixed => [],
    );
    $data{last_seven_days} = \%last_seven_days;

    %problems_reported_by_period = stuff_by_day_or_year('day',
        'Problem',
        state => [ FixMyStreet::DB::Result::Problem->visible_states() ],
        confirmed => { '>=', \"current_timestamp-'8 days'::interval" },
    );
    %problems_fixed_by_period = stuff_by_day_or_year('day',
        'Comment',
        confirmed => { '>=', \"current_timestamp-'8 days'::interval" },
        problem_state => [ FixMyStreet::DB::Result::Problem->fixed_states() ],
    );
    my %problems_updated_by_period = stuff_by_day_or_year('day',
        'Comment',
        confirmed => { '>=', \"current_timestamp-'8 days'::interval" },
    );

    my $date = DateTime->today->subtract(days => 7);
    while ($date < DateTime->today) {
        push @{$last_seven_days{problems}}, $problems_reported_by_period{$date->day} || 0;
        push @{$last_seven_days{fixed}}, $problems_fixed_by_period{$date->day} || 0;
        push @{$last_seven_days{updated}}, $problems_updated_by_period{$date->day} || 0;
        $date->add(days => 1);
    }
    $last_seven_days{problems_total} = sum @{$last_seven_days{problems}};
    $last_seven_days{fixed_total} = sum @{$last_seven_days{fixed}};
    $last_seven_days{updated_total} = sum @{$last_seven_days{updated}};

    my(@top_five_bodies);
    $data{top_five_bodies} = \@top_five_bodies;

    my $bodies = FixMyStreet::DB->resultset('Body')->search;
    my $substmt = "select min(id) from comment where me.problem_id=comment.problem_id and (problem_state in ('fixed', 'fixed - council', 'fixed - user') or mark_fixed)";
    while (my $body = $bodies->next) {
        my $subquery = FixMyStreet::DB->resultset('Comment')->to_body($body)->search({
            -or => [
                problem_state => [ FixMyStreet::DB::Result::Problem->fixed_states() ],
                mark_fixed => 1,
            ],
            'me.id' => \"= ($substmt)",
            'me.state' => 'confirmed',
        }, {
            select   => [
                { extract => "epoch from me.confirmed-problem.confirmed", -as => 'time' },
            ],
            as => [ qw/time/ ],
            rows => 100,
            order_by => { -desc => 'me.confirmed' },
            join => 'problem'
        })->as_subselect_rs;
        my $avg = $subquery->search({
        }, {
            select => [ { avg => "time" } ],
            as => [ qw/avg/ ],
        })->first->get_column('avg');
        push @top_five_bodies, { name => $body->name, days => int($avg / 60 / 60 / 24 + 0.5) }
            if defined $avg;
    }
    @top_five_bodies = sort { $a->{days} <=> $b->{days} } @top_five_bodies;
    $data{average} = @top_five_bodies
        ? int((sum map { $_->{days} } @top_five_bodies) / @top_five_bodies + 0.5) : undef;

    @top_five_bodies = @top_five_bodies[0..4] if @top_five_bodies > 5;


    my $last_seven_days = FixMyStreet::DB->resultset("Problem")->search({
        confirmed => { '>=', \"current_timestamp-'7 days'::interval" },
    })->count;
    my @top_five_categories = FixMyStreet::DB->resultset("Problem")->search({
        confirmed => { '>=', \"current_timestamp-'7 days'::interval" },
        category => { '!=', 'Other' },
    }, {
        select => [ 'category', { count => 'id' } ],
        as => [ 'category', 'count' ],
        group_by => 'category',
        rows => 5,
        order_by => { -desc => 'count' },
    });
    $data{top_five_categories} = [ map {
        { category => $_->category, count => $_->get_column('count') }
        } @top_five_categories ];
    foreach (@top_five_categories) {
        $last_seven_days -= $_->get_column('count');
    }
    $data{other_categories} = $last_seven_days;

    my $body = encode_json( \%data );
    File::Path::mkpath( FixMyStreet->path_to( '../data/' )->stringify );
    File::Slurp::write_file( FixMyStreet->path_to( '../data/all-reports-dashboard.json' )->stringify, \$body );
}

sub stuff_by_day_or_year {
    my $period = shift;
    my $table = shift;
    my %params = @_;
    my $results = FixMyStreet::DB->resultset($table)->search({
        %params
    }, {
        select => [ { extract => \"$period from confirmed", -as => $period }, { count => 'id' } ],
        as => [ $period, 'count' ],
        group_by => [ $period ],
    });
    my %out;
    while (my $row = $results->next) {
        my $p = $row->get_column($period);
        $out{$p} = $row->get_column('count');
    }
    return %out;
}

1;