using UnityEngine;

public interface EnchantmentScript
{
    Sprite GetSprite();
    int currentDuration { get; set; }
    EntityScript.Modifiers ModifierEffects();
    void OnAttackEffect(GameObject target, GameObject wielder);
    void EndOfTurnEffect(GameObject wielder);
    void EndEffect(GameObject wielder);
}
