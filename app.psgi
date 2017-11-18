#!/usr/bin/perl -w
use strict;

use Router::Resource;
use Plack::Builder;
use File::Spec::Functions qw{catfile};
use LWP::UserAgent;
use File::Slurp;
use YAML;
use Template;
use JSON;
use FindBin;
use Encode;
use Plack::Request;

my $IIIF_BASE_URL = 'https://iiif.echodin.net/manifests/';
my $PHOTOSETS_FILE = catfile($FindBin::RealBin, 'photosets.json');

my $ua = LWP::UserAgent->new;
my $template = Template->new({
    INCLUDE_PATH => [$FindBin::RealBin],
    ENCODING => 'utf8',
});

sub get_manifest {
    my ($photoset) = @_;
    my $res = $ua->get($IIIF_BASE_URL . $photoset . '/manifest');
    if ($res->is_error) {
        die [$res->code, ['Content-Type' => 'text/plain; charset=UTF-8'], [$res->status_line]];
    }
    my $json = $res->decoded_content;
    return decode_json($json);
}

sub get_metadata {
    my ($manifest) = @_;
    return {
        title  => $manifest->{label},
        rights => $manifest->{attribution},
        map { lc($_->{label}) => $_->{value} } @{ $manifest->{metadata} },
    };
}

my $router = router {
    resource '/' => sub {
        GET {
            my $photosets = decode_json(read_file($PHOTOSETS_FILE));
            $template->process(
                'home.html',
                {
                    photosets => $photosets,
                },
                \my $output,
            );
            return [200, ['Content-Type' => 'text/html; charset=UTF-8'], [encode_utf8($output)]];
        };
    };

    resource '/{photoset}' => sub {
        GET {
            my ($env, $params) = @_;
            my $manifest = eval { get_manifest($params->{photoset}); };
            return $@ if $@;
            my @canvases = @{ $manifest->{sequences}[0]{canvases} };

            my @thumbnails = map { $_->{thumbnail} } @canvases;
            $template->process(
                'index.tt',
                {
                    base_uri => Plack::Request->new($env)->base,
                    files    => [ map { $_->{'@id'} } @thumbnails ],
                    gallery  => get_metadata($manifest),
                },
                \my $output,
            );
            return [200, ['Content-Type' => 'text/html; charset=UTF-8'], [encode_utf8($output)]];
        };
    };
    resource '/{photoset}/{image}' => sub {
        GET {
            my ($env, $params) = @_;
            my $manifest = eval { get_manifest($params->{photoset}); };
            return $@ if $@;
            my @canvases = @{ $manifest->{sequences}[0]{canvases} };

            my $count = scalar @canvases;
            my $i = $params->{image};

            if ($i < 1 || $i > $count) {
                return [404, ['Content-Type' => 'text/plain; charset=UTF-8'], ['Not Found']];
            }

            my $image = (map { $_->{images}[0] } @canvases)[$i - 1];
            my $aspect_ratio = $image->{resource}{width} / $image->{resource}{height};
            my $w = $aspect_ratio > 1 ? 1024 : 680;
            my $this = $image->{resource}{service}{'@id'} . "/full/$w,/0/default.jpg";

            $template->process(
                'photo.html',
                {
                    prev    => ($i > 1),
                    next    => ($i < $count),
                    file    => $this,
                    index   => int($i),
                    count   => $count,
                    gallery => get_metadata($manifest),
                },
                \my $output,
            );
            return [200, ['Content-Type' => 'text/html; charset=UTF-8'], [encode_utf8($output)]];
        };
    };
};

builder {
    # serve static CSS files
    enable 'Static', path => qr{\.css$}, root => '';
    # application
    sub { $router->dispatch(shift) };
};
