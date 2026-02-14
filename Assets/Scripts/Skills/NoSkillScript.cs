using UnityEngine;

public class NoSkillScript : MonoBehaviour, Skill
{
    private int currentCooldown = 0;
    private Sprite skillSprite;
    private int _skillBarPosition;
    public int skillBarPosition
    {
        get
        {
            return _skillBarPosition;
        }
        set
        {
            _skillBarPosition = value;
        }
    }

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

    public float GetRadius()
    {
        return 0;
    }

    public float GetDistance()
    {
        return 0;
    }

    public int GetSkillDuration()
    {
        return 0;
    }

    public int GetStunDuration()
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

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        return -1;
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
    }

    void Awake()
    {
        skillSprite = Resources.Load<Sprite>("Skills/NoSkill");
    }
}
