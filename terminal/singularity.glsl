void mainImage(out vec4 fragColor, vec2 fragCoord)
{
    vec2 uv = fragCoord.xy / iResolution.xy;
    float i;
    vec2 r = iResolution.xy,
         p = ( fragCoord + fragCoord - r ) / (r.y * 0.7),
         d = vec2(-1,1), 
         q = 5.*p - d, 
         c = p * mat2(1, 1, d/(0.1 + 5./dot(q,q)) ),
         v = c * mat2(cos( log(length(c)) +iTime*.2 + vec4(0,33,11,0))) * 5.;
   
    for(fragColor*=i; i++ < 9.; fragColor += 1.0 + sin(v.xyyx) )
        v += 0.7* sin(v.yx*i+iTime) / i + 0.5;
        
    i = length( sin(v/0.3)*0.2 + c*vec2(1,2) ) - 1.0;

    fragColor = 1. - exp( -exp( c.x * vec4(0.6,-0.4,-1,0) ) 
                   / fragColor 
                   / ( 1.0 + i*i )
                   / ( 0.5 + 3.5 *exp( 0.3*c.y - dot(c,c) ) )
                   / ( 0.03 + abs( length(p)-0.7 ) )
             );

    vec4 terminalColor = texture(iChannel0, uv);
    float mask = 1.0 - step(0.5, dot(terminalColor.rgb, vec3(1.0)));
    vec3 blendedColor = mix(fragColor.rgb, terminalColor.rgb, mask);

    fragColor = vec4(blendedColor, terminalColor.a);
}
