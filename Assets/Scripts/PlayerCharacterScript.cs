using UnityEngine;

public interface PlayerCharacterScript
{
    bool finishedBuilding { get; }
    Transform mainHand { get; }
    Transform offHand { get; }
    Transform body { get; }
    Transform hands { get; }
    Transform legs { get; }
    Transform feet { get; }
    GameObject mainHandWeapon { get; }
    GameObject offHandWeapon { get; }
    GameObject coat { get; }
    GameObject gloves { get; }
    GameObject pants { get; }
    GameObject boots { get; }
    Transform inventory { get; }
    int inventorySize { get; }
    GameObject[] inventoryItems { get; }
    Transform utilitySkills { get; }
    int utilitySkillSlots { get; set; }
    GameObject[] equippedSkills { get; }

    void MoveTo(Vector3 targetPosition);

    int GetSkillCooldown(string skillName);
    void SetSkillCooldown(string skillName, int number);
}
