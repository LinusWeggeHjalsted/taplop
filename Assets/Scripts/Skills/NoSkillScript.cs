using UnityEngine;

public class NoSkillScript : MonoBehaviour, Skill
{
    private int currentCooldown = 0;
    private Sprite skillSprite;

    public string GetSkillName()
    {
        return "No Skill";
    }

    public string GetSkillType()
    {
        return "";
    }

    public string GetDescription()
    {
        return "";
    }

    public float GetRange()
    {
        return 0;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return 0;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
    }

    public int EnemyPriority(Vector3 fromPosition)
    {
        return -1;
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        Debug.Log("no skill equipped in this slot");
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        Debug.Log("no skill equipped in this slot");
    }

    void Start()
    {
        skillSprite = Resources.Load<Sprite>("Skill Sprites/NoSkill");
    }
}
